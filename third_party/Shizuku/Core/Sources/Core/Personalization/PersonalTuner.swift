import Foundation

// MARK: - 場面ごとの自己調整（llm-ime、フェーズ 3）
//
// 本人の記録（直近 2 週間）だけから、場面ごとに次の値を合わせ直す（記録の薄い場面はアプリ、全体の値を使う）。
// - 続き予測の自信のしきい値: 入力が止まっている間に記録を再生し（足切りなしで生成してトークンごとの確率を集める）、
//   節約できる文字が最も多く、精度が既定（−0.7）のときより下がらない値を選ぶ
// - 放置で続きを自動生成するまでの待ち時間・「もしかして」のしきい値: 出したものの採用率で少しずつ動かす
// どの値も、評価で確かめた範囲の中でだけ動かす。変えたら「試行」とし、変える前の成績を覚えておく。変えた後の成績が
// 落ちたら自動で元に戻し、同じ向きには 7 日間動かさない。
// 合成のログでは動かさない（記録は本人が IME で確定したものだけ）。

public final class PersonalTuner: @unchecked Sendable {
    public static let shared = PersonalTuner()

    public enum Knob: String, CaseIterable, Codable, Sendable {
        /// 入力中の続き予測の自信のしきい値（対数確率）
        case completionThreshold
        /// 放置で続きを自動生成するまでの秒数
        case idleDelay
        /// 「もしかして」のしきい値への足し算
        case typoMarginOffset
        /// 放置で続きを出すまでを、本人のリズム（いつもより長く手を止めたとき）にする（1）か、決まった秒数（0）か
        case idleRhythm
        /// 本人のリズムのとき、手を止めた長さの何割より長ければ出すか（分位）
        case idleQuantile
        /// 言い直しを出すのに要る、同じ言い直しの回数（場面の段だけ）
        case rewriteRepeats
    }

    public struct Bounds: Sendable {
        public var defaultValue: Double
        public var min: Double
        public var max: Double
        public var step: Double
    }

    public static let bounds: [Knob: Bounds] = [
        .completionThreshold: .init(defaultValue: -0.7, min: -1.0, max: -0.5, step: 0.1),
        .idleDelay: .init(defaultValue: 3.0, min: 2.0, max: 6.0, step: 0.5),
        .typoMarginOffset: .init(defaultValue: 0, min: -0.5, max: 1.0, step: 0.25),
        .idleRhythm: .init(defaultValue: 0, min: 0, max: 1, step: 1),
        .idleQuantile: .init(defaultValue: PersonalRhythm.defaultQuantile, min: 0.8, max: 0.95, step: 0.05),
        .rewriteRepeats: .init(defaultValue: Double(PersonalRewrite.defaultRepeats), min: 2, max: 3, step: 1),
    ]

    /// 言い直しの回数を 3 → 2 に試すのに要る、3 回のときの出した数と採用率（本人の判断）
    public static let rewriteRelaxShown = 20
    public static let rewriteRelaxAcceptance = 0.7

    /// 1 つの段（場面・アプリ・全体）の、1 つのつまみの状態
    public struct Setting: Codable, Equatable, Sendable {
        public var value: Double
        /// 試行中なら、変える前の値・成績・始めた時刻
        public var previous: Double?
        public var baselineAcceptance: Double?
        public var baselineSaved: Double?
        public var since: Double?
        /// 元に戻した向き（+1 / −1）と、その向きに動かさない期限
        public var frozenDirection: Int = 0
        public var frozenUntil: Double = 0
        /// 最後に変えた時刻（同じつまみを続けて動かさない）
        public var changedAt: Double = 0

        public var isOnTrial: Bool {
            self.previous != nil
        }
    }

    /// 段のキー（場面のキー、"app:<bundle ID>"、"global"）→ つまみ → 状態
    public private(set) var settings: [String: [Knob: Setting]] = [:]

    /// 段の判定に必要な数
    public static let minimumReplaySamples = 30
    /// 再生でしきい値を既定から動かすのは、節約文字が既定より 10% 以上かつ 5 文字以上多いときだけ（数百の位置では、わずかな差は偶然）
    public static let minimumReplayGain = 0.1
    public static let minimumReplayGainCharacters = 5
    public static let minimumShown = 20
    /// 試行の判定に必要な、変えた後の数
    public static let trialEvents = 30
    /// 元に戻す基準（採用率が 5 ポイント以上、または節約文字が 5% 以上下がったら）
    public static let revertAcceptanceDrop = 0.05
    public static let revertSavedRatio = 0.95
    public static let freezeDays = 7.0
    public static let window: Double = 14 * 86400

    private var persist: ((String, Knob, Setting?) -> Void)?

    public init() {}

    /// 保存先を差し込む（PersonalLearner の記録）。起動時に読み込んだ状態も渡す
    public func attach(settings: [String: [Knob: Setting]], persist: @escaping (String, Knob, Setting?) -> Void) {
        self.settings = settings
        self.persist = persist
    }

    public static func levelKeys(for scene: PersonalScene) -> [String] {
        // 場所があれば、場所つきの場面 → 場面（場所を除く）→ アプリ → 全体。なければ今までどおり
        scene.levelKeys
    }

    /// 今の場面での値（調整していなければ nil＝既定）
    public func value(_ knob: Knob, scene: PersonalScene) -> Double? {
        for key in Self.levelKeys(for: scene) {
            if let setting = self.settings[key]?[knob] {
                return setting.value
            }
        }
        return nil
    }

    private func set(_ setting: Setting?, level: String, knob: Knob) {
        self.settings[level, default: [:]][knob] = setting
        self.persist?(level, knob, setting)
    }

    /// 自己調整をすべて取り消す（既定に戻す）
    public func reset() {
        for (level, knobs) in self.settings {
            for knob in knobs.keys {
                self.persist?(level, knob, nil)
            }
        }
        self.settings.removeAll()
    }

    /// 条件に合う段（そのアプリの場面・アプリの段）の調整をすべて消す
    public func forget(levels belongs: (String) -> Bool) {
        for level in self.settings.keys where belongs(level) {
            for knob in self.settings[level]?.keys ?? [:].keys {
                self.persist?(level, knob, nil)
            }
            self.settings[level] = nil
        }
    }

    // MARK: 続き予測のしきい値（記録の再生から選ぶ）

    /// 再生した 1 位置: トークンごとの記録と正解
    public struct ReplayOutcome: Sendable {
        public var levels: [String]
        public var pieces: [NextTextCompletionEngine.Piece]
        public var gold: String

        public init(levels: [String], pieces: [NextTextCompletionEngine.Piece], gold: String) {
            self.levels = levels
            self.pieces = pieces
            self.gold = gold
        }
    }

    public struct ThresholdScore: Equatable, Sendable {
        public var threshold: Double
        public var shown: Int
        public var correct: Int
        public var savedCharacters: Int
        public var samples: Int

        public var accuracy: Double {
            self.shown == 0 ? 0 : Double(self.correct) / Double(self.shown)
        }

        public var savedPerSample: Double {
            self.samples == 0 ? 0 : Double(self.savedCharacters) / Double(self.samples)
        }
    }

    /// しきい値ごとの成績（候補 = suggestion(threshold)、正解 = 正解の先頭が候補で始まる）
    public static func scores(
        _ outcomes: [ReplayOutcome], suggestion: ([NextTextCompletionEngine.Piece], Float) -> String?
    ) -> [ThresholdScore] {
        let bounds = Self.bounds[.completionThreshold]!
        var thresholds: [Double] = []
        var t = bounds.min
        while t <= bounds.max + 1e-9 {
            thresholds.append((t * 10).rounded() / 10)
            t += bounds.step
        }
        return thresholds.map { threshold in
            var score = ThresholdScore(threshold: threshold, shown: 0, correct: 0, savedCharacters: 0, samples: outcomes.count)
            for outcome in outcomes {
                guard let text = suggestion(outcome.pieces, Float(threshold)) else {
                    continue
                }
                score.shown += 1
                if outcome.gold.precomposedStringWithCompatibilityMapping.hasPrefix(text.precomposedStringWithCompatibilityMapping) {
                    score.correct += 1
                    score.savedCharacters += text.count
                }
            }
            return score
        }
    }

    /// 節約文字が最も多く、精度が既定のしきい値のときより下がらないしきい値（同じなら既定に近い方）。
    /// 既定より十分に多くなければ既定のまま
    public static func bestThreshold(_ scores: [ThresholdScore]) -> Double? {
        let defaultValue = Self.bounds[.completionThreshold]!.defaultValue
        guard let base = scores.first(where: { abs($0.threshold - defaultValue) < 1e-6 }) else {
            return nil
        }
        guard let best = scores
            .filter({ $0.accuracy >= base.accuracy - 1e-9 || $0.shown == 0 })
            .max(by: { a, b in
                (a.savedPerSample, -abs(a.threshold - defaultValue)) < (b.savedPerSample, -abs(b.threshold - defaultValue))
            }) else {
            return nil
        }
        let gain = best.savedCharacters - base.savedCharacters
        guard Double(best.savedCharacters) >= Double(base.savedCharacters) * (1 + Self.minimumReplayGain),
              gain >= Self.minimumReplayGainCharacters else {
            return defaultValue
        }
        return best.threshold
    }

    /// 再生の結果から段ごとのしきい値を選び、変えるものは試行として始める（変えた段のキーを返す）
    @discardableResult
    public func applyReplay(
        _ outcomes: [ReplayOutcome],
        baseline: (String) -> (acceptance: Double, saved: Double)?,
        now: Double,
        suggestion: ([NextTextCompletionEngine.Piece], Float) -> String? = NextTextCompletionEngine.suggestion(from:threshold:)
    ) -> [String] {
        var byLevel: [String: [ReplayOutcome]] = [:]
        for outcome in outcomes {
            for level in outcome.levels {
                byLevel[level, default: []].append(outcome)
            }
        }
        var changed: [String] = []
        for (level, items) in byLevel where items.count >= Self.minimumReplaySamples {
            guard let best = Self.bestThreshold(Self.scores(items, suggestion: suggestion)) else {
                continue
            }
            if self.propose(.completionThreshold, value: best, level: level, baseline: baseline(level), now: now) {
                changed.append(level)
            }
        }
        return changed
    }

    // MARK: 採用率で動かす（待ち時間・「もしかして」）

    /// 採用率が低ければ「出しにくく」（待ち時間を長く・しきい値を上げる）、高ければ「出しやすく」する。変えたら true
    @discardableResult
    public func adjustByAcceptance(
        _ knob: Knob, level: String, shown: Int, accepted: Int, now: Double, low: Double = 0.15, high: Double = 0.4
    ) -> Bool {
        guard knob != .completionThreshold, shown >= Self.minimumShown,
              let bounds = Self.bounds[knob] else {
            return false
        }
        let rate = Double(accepted) / Double(shown)
        let current = self.settings[level]?[knob]?.value ?? bounds.defaultValue
        let target: Double
        if rate < low {
            target = current + bounds.step
        } else if rate > high {
            target = current - bounds.step
        } else {
            return false
        }
        return self.propose(knob, value: target, level: level, baseline: (rate, 0), now: now)
    }

    /// 値を変える提案。範囲に収め、試行中・凍結中・最近変えたばかりなら変えない。変えたら試行として始める
    func propose(_ knob: Knob, value: Double, level: String, baseline: (acceptance: Double, saved: Double)?, now: Double) -> Bool {
        guard let bounds = Self.bounds[knob] else {
            return false
        }
        let clamped = Swift.min(bounds.max, Swift.max(bounds.min, value))
        var setting = self.settings[level]?[knob] ?? Setting(value: bounds.defaultValue)
        guard abs(clamped - setting.value) > 1e-9, !setting.isOnTrial, now - setting.changedAt >= 86400 else {
            return false
        }
        let direction = clamped > setting.value ? 1 : -1
        if setting.frozenDirection == direction, now < setting.frozenUntil {
            return false
        }
        setting.previous = setting.value
        setting.baselineAcceptance = baseline?.acceptance
        setting.baselineSaved = baseline?.saved
        setting.since = now
        setting.value = clamped
        setting.changedAt = now
        self.set(setting, level: level, knob: knob)
        return true
    }

    // MARK: 迷いの検知（放置で続きを出すまでを本人のリズムに）

    /// その段で本人のリズムを使っているか（試行中も含む）
    public func usesRhythm(level: String) -> Bool {
        (self.settings[level]?[.idleRhythm]?.value ?? 0) >= 1
    }

    /// 手を止めた長さが十分にたまった段で、本人のリズムの待ち時間を試行として始める（始めたら true）。
    /// 変える前の、決まった秒数での採用率（baselineAcceptance）を覚え、変えた後に 5 ポイント以上下がったら元に戻す
    @discardableResult
    public func activateRhythm(level: String, pauses: Int, baselineAcceptance: Double?, now: Double) -> Bool {
        guard pauses >= PersonalRhythm.minimumPauses, !self.usesRhythm(level: level) else {
            return false
        }
        return self.propose(.idleRhythm, value: 1, level: level, baseline: baselineAcceptance.map { ($0, 0) }, now: now)
    }

    /// 放置で出した続きの採用率で待ち時間を動かす。本人のリズムを使っている段は分位を、そうでなければ秒数を動かす
    /// （リズムを試している間は動かさない）
    @discardableResult
    public func adjustIdleByAcceptance(level: String, shown: Int, accepted: Int, now: Double) -> Bool {
        if self.usesRhythm(level: level) {
            guard self.settings[level]?[.idleRhythm]?.isOnTrial != true else {
                return false
            }
            return self.adjustByAcceptance(.idleQuantile, level: level, shown: shown, accepted: accepted, now: now)
        }
        return self.adjustByAcceptance(.idleDelay, level: level, shown: shown, accepted: accepted, now: now)
    }

    /// 放置で続きを出すまでの待ち時間（秒）。本人のリズムを使う段があり、手を止めた長さが十分にあればその分位、
    /// なければ調整した秒数、それもなければ nil（本体の既定 3 秒）
    public func idleDelay(scene: PersonalScene, pauses: [String: PersonalRhythm.Histogram]) -> Double? {
        let levels = Self.levelKeys(for: scene)
        if levels.contains(where: { self.usesRhythm(level: $0) }),
           let delay = PersonalRhythm.personalDelay(
            histograms: levels.map { pauses[$0] }, quantile: self.value(.idleQuantile, scene: scene) ?? PersonalRhythm.defaultQuantile
           ) {
            return delay
        }
        return self.value(.idleDelay, scene: scene)
    }

    // MARK: 言い直し

    /// その場面で言い直しを出すのに要る回数（場面の段だけ。調整していなければ 3）
    public func rewriteRepeats(scene: PersonalScene) -> Int {
        Int(scene.sceneKeys.compactMap { self.settings[$0]?[.rewriteRepeats]?.value }.first ?? Double(PersonalRewrite.defaultRepeats))
    }

    /// 3 回で出した言い直しの採用率が十分に高い場面（20 回以上出して 70% 以上）で、2 回を試行として始める。
    /// 採用率が 5 ポイント以上下がったら 3 に戻す（evaluateTrial）
    @discardableResult
    public func relaxRewriteRepeats(level: String, shown: Int, accepted: Int, now: Double) -> Bool {
        guard PersonalScene(key: level) != nil, shown >= Self.rewriteRelaxShown else {
            return false
        }
        let acceptance = Double(accepted) / Double(shown)
        guard acceptance >= Self.rewriteRelaxAcceptance else {
            return false
        }
        return self.propose(.rewriteRepeats, value: 2, level: level, baseline: (acceptance, 0), now: now)
    }

    // MARK: 試行の判定（変えた後の成績が落ちたら元に戻す）

    public enum TrialDecision: Equatable, Sendable {
        case pending
        case kept
        case reverted
    }

    /// 試行中の値を、変えた後の成績（採用率と、続き予測なら機会あたりの節約文字）で判定する
    @discardableResult
    public func evaluateTrial(
        _ knob: Knob, level: String, events: Int, acceptance: Double, saved: Double?, now: Double
    ) -> TrialDecision {
        guard var setting = self.settings[level]?[knob], let previous = setting.previous else {
            return .pending
        }
        guard events >= Self.trialEvents else {
            return .pending
        }
        var worse = false
        if let base = setting.baselineAcceptance, acceptance < base - Self.revertAcceptanceDrop {
            worse = true
        }
        if let base = setting.baselineSaved, let saved, base > 0, saved < base * Self.revertSavedRatio {
            worse = true
        }
        if worse {
            setting.frozenDirection = setting.value > previous ? 1 : -1
            setting.frozenUntil = now + Self.freezeDays * 86400
            setting.value = previous
        }
        setting.previous = nil
        setting.baselineAcceptance = nil
        setting.baselineSaved = nil
        setting.since = nil
        // 既定の値に戻って凍結もなければ、記録を消す
        if let bounds = Self.bounds[knob], abs(setting.value - bounds.defaultValue) < 1e-9, setting.frozenDirection == 0 {
            self.set(nil, level: level, knob: knob)
        } else {
            self.set(setting, level: level, knob: knob)
        }
        return worse ? .reverted : .kept
    }

    // MARK: 動かしてよいか（電源・省電力）

    public struct Conditions: Sendable {
        public var onACPower: Bool
        public var lowPowerMode: Bool
        public var powerSavingModel: Bool
        public var completionEnabled: Bool
        public var secondsSinceLastKey: TimeInterval
        public var secondsSinceLastReplay: TimeInterval
        public var newCommits: Int

        public init(
            onACPower: Bool, lowPowerMode: Bool, powerSavingModel: Bool, completionEnabled: Bool,
            secondsSinceLastKey: TimeInterval, secondsSinceLastReplay: TimeInterval, newCommits: Int
        ) {
            self.onACPower = onACPower
            self.lowPowerMode = lowPowerMode
            self.powerSavingModel = powerSavingModel
            self.completionEnabled = completionEnabled
            self.secondsSinceLastKey = secondsSinceLastKey
            self.secondsSinceLastReplay = secondsSinceLastReplay
            self.newCommits = newCommits
        }
    }

    /// 記録の再生（ANE を使う）をしてよいか: 電源につながっていて、低電力モード・省電力モデルでなく、10 分入力がなく、
    /// 前回から 6 時間以上たち、新しい確定が 50 件以上
    /// 省電力モデル（E2B）。続き予測がこのモデルで動いているときは再生しない（本人の判断: 電源につながっていても）
    public static let powerSavingModelName = "gemma4-e2b-ane"

    /// 実際に使う続き予測のモデル（設定画面で選んだもの。使えなければ代わりのもの）が省電力モデルか
    public static func isPowerSavingModel(_ directory: URL) -> Bool {
        directory.lastPathComponent == Self.powerSavingModelName
    }

    public static func mayReplay(_ c: Conditions) -> Bool {
        c.onACPower && !c.lowPowerMode && !c.powerSavingModel && c.completionEnabled
            && c.secondsSinceLastKey >= 600 && c.secondsSinceLastReplay >= 6 * 3600 && c.newCommits >= 50
    }

    /// 1 回の再生の時間の上限（秒）
    public static let replayBudget: TimeInterval = 30
}
