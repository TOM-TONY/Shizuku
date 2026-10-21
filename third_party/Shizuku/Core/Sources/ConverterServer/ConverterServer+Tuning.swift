import Core
import Foundation
import IOKit.ps

// MARK: - 場面ごとの自己調整の実行（llm-ime、フェーズ 3）
//
// 10 分ごとに、試行中の値の判定（記録の集計だけ。軽い）と、採用率による待ち時間・「もしかして」の調整を行う。
// 続き予測のしきい値は、電源につながっていて低電力モードでなく、続き予測のモデルが省電力モデル（E2B）でなく、10 分入力がないときに、記録を再生して選ぶ
// （6 時間に 1 回まで、1 回 30 秒まで、優先度は低く、キー入力が来たらすぐやめる）。学習のスイッチか自己調整のスイッチが
// オフなら何もしない（調整した値も使わない）。

@MainActor
final class PersonalTuningScheduler {
    static let shared = PersonalTuningScheduler()

    private var timer: Timer?
    private var lastKeyEvent = Date()
    private var lastReplay = Date.distantPast
    private var commitsAtLastReplay = 0
    private var replaying = false

    nonisolated static var isActive: Bool {
        PersonalLearner.isEnabled && Config.PersonalLearningSelfTuning().value
    }

    func start() {
        guard self.timer == nil else {
            return
        }
        self.timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated {
                PersonalTuningScheduler.shared.tick()
            }
        }
    }

    /// キー入力のたびに呼ぶ（再生していればすぐやめる）
    func noteKeyEvent() {
        self.lastKeyEvent = Date()
        if self.replaying {
            NextTextCompletionEngine.shared.cancelBackground()
        }
    }

    static var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            // 電源の情報がない（デスクトップ機など）は電源につながっているとみなす
            return true
        }
        return type == kIOPMACPowerKey
    }

    func tick(now: Date = Date()) {
        ConverterResourceStatus.refresh()
        // 解析と学習の夜の自動実行（自己調整のスイッチとは別。学習のスイッチ・夜の自動実行の設定に従う）
        LabController.shared.considerNightly(
            now: now, secondsSinceLastKey: now.timeIntervalSince(self.lastKeyEvent), onACPower: Self.isOnACPower
        )
        guard Self.isActive else {
            return
        }
        let learner = PersonalLearner.shared
        let tuner = PersonalTuner.shared
        let nowTS = now.timeIntervalSince1970
        self.evaluateTrials(learner: learner, tuner: tuner, now: nowTS)
        self.adjustByAcceptance(learner: learner, tuner: tuner, now: nowTS)
        self.activateRhythm(learner: learner, tuner: tuner, now: nowTS)
        let conditions = PersonalTuner.Conditions(
            onACPower: Self.isOnACPower,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            // 設定画面で選んだモデル（実際に読み込むもの）で判断する。古い省電力のスイッチは画面に出ないので見ない
            powerSavingModel: PersonalTuner.isPowerSavingModel(
                NextTextCompletionEngine.modelDirectoryURL(powerSaving: Config.NextTextCompletionPowerSaving().value)
            ),
            completionEnabled: Config.NextTextCompletion().value,
            secondsSinceLastKey: now.timeIntervalSince(self.lastKeyEvent),
            secondsSinceLastReplay: now.timeIntervalSince(self.lastReplay),
            newCommits: learner.commitCount - self.commitsAtLastReplay
        )
        if !self.replaying, ResourceBudget.current.replay, PersonalTuner.mayReplay(conditions) {
            self.replay(learner: learner, tuner: tuner, now: now)
        }
    }

    /// 場面ごとの集計を、段（場面・アプリ・全体）ごとに足し合わせる
    static func byLevel<T>(_ perScene: [String: T], combine: (T, T) -> T) -> [String: T] {
        var result: [String: T] = [:]
        for (sceneKey, value) in perScene {
            guard let scene = PersonalScene(key: sceneKey) else {
                continue
            }
            for level in PersonalTuner.levelKeys(for: scene) {
                result[level] = result[level].map { combine($0, value) } ?? value
            }
        }
        return result
    }

    /// 続き予測の成績（採用率、機会＝確定あたりの節約文字、出した数）を段ごとに
    static func completionStats(
        reactions: [String: [String: (count: Int, sum: Int)]], commits: [String: Int]
    ) -> [String: (acceptance: Double, saved: Double, shown: Int)] {
        let perScene = reactions.mapValues { kinds in
            [kinds["completion_accepted"]?.count ?? 0, kinds["completion_ignored"]?.count ?? 0, kinds["completion_accepted"]?.sum ?? 0]
        }
        let totals = byLevel(perScene) { zip($0, $1).map(+) }
        let opportunities = byLevel(commits, combine: +)
        var result: [String: (acceptance: Double, saved: Double, shown: Int)] = [:]
        for (level, value) in totals {
            let shown = value[0] + value[1]
            result[level] = (
                shown == 0 ? 0 : Double(value[0]) / Double(shown),
                Double(value[2]) / Double(max(1, opportunities[level] ?? 0)),
                shown
            )
        }
        return result
    }

    /// 「出した数・使った数」を段ごとに（放置の続き: idle_shown / idle_accepted、「もしかして」: 使った＋使わなかった / 使った）
    static func acceptanceCounts(_ knob: PersonalTuner.Knob, reactions: [String: [String: (count: Int, sum: Int)]]) -> [String: (shown: Int, accepted: Int)] {
        let perScene = reactions.mapValues { kinds -> [Int] in
            switch knob {
            case .idleDelay, .idleRhythm, .idleQuantile:
                return [kinds["idle_shown"]?.count ?? 0, kinds["idle_accepted"]?.count ?? 0]
            case .rewriteRepeats:
                let accepted = kinds["rewrite_accepted"]?.count ?? 0
                return [accepted + (kinds["rewrite_ignored"]?.count ?? 0), accepted]
            case .typoMarginOffset:
                let accepted = kinds["typo_accepted"]?.count ?? 0
                return [accepted + (kinds["typo_ignored"]?.count ?? 0), accepted]
            case .completionThreshold:
                let accepted = kinds["completion_accepted"]?.count ?? 0
                return [accepted + (kinds["completion_ignored"]?.count ?? 0), accepted]
            }
        }
        return byLevel(perScene) { zip($0, $1).map(+) }.mapValues { ($0[0], $0[1]) }
    }

    private func evaluateTrials(learner: PersonalLearner, tuner: PersonalTuner, now: Double) {
        for (level, knobs) in tuner.settings {
            for (knob, setting) in knobs {
                guard let since = setting.since else {
                    continue
                }
                let reactions = learner.reactionTotals(since: since)
                if knob == .completionThreshold {
                    let stats = Self.completionStats(reactions: reactions, commits: learner.commitTotals(since: since))[level]
                    tuner.evaluateTrial(knob, level: level, events: stats?.shown ?? 0, acceptance: stats?.acceptance ?? 0, saved: stats?.saved, now: now)
                } else {
                    let counts = Self.acceptanceCounts(knob, reactions: reactions)[level] ?? (0, 0)
                    let acceptance = counts.shown == 0 ? 0 : Double(counts.accepted) / Double(counts.shown)
                    let decision = tuner.evaluateTrial(knob, level: level, events: counts.shown, acceptance: acceptance, saved: nil, now: now)
                    if decision != .pending {
                        // 判定の記録（あとで前後を比べる）。本人の文章は含まない
                        learner.recordReaction(
                            kind: "tuning_trial", scene: nil, a: knob.rawValue + "@" + level,
                            b: decision == .kept ? "kept" : "reverted", n: Int((acceptance * 1000).rounded())
                        )
                    }
                }
            }
        }
    }

    private func adjustByAcceptance(learner: PersonalLearner, tuner: PersonalTuner, now: Double) {
        let reactions = learner.reactionTotals(since: now - PersonalTuner.window)
        // 放置で続きを自動生成: 出した文のうち Tab で入れた割合（低ければ待ち時間を長く・分位を上げる）
        for (level, counts) in Self.acceptanceCounts(.idleDelay, reactions: reactions) {
            tuner.adjustIdleByAcceptance(level: level, shown: counts.shown, accepted: counts.accepted, now: now)
        }
        // 言い直し: 3 回で出したものの採用率が高い場面で、2 回を試す（場面の段だけ）
        for (level, counts) in Self.acceptanceCounts(.rewriteRepeats, reactions: reactions) {
            tuner.relaxRewriteRepeats(level: level, shown: counts.shown, accepted: counts.accepted, now: now)
        }
        // 「もしかして」: 出した訂正のうち使った割合（低ければしきい値を上げる）
        for (level, counts) in Self.acceptanceCounts(.typoMarginOffset, reactions: reactions) {
            tuner.adjustByAcceptance(.typoMarginOffset, level: level, shown: counts.shown, accepted: counts.accepted, now: now, low: 0.3, high: 0.6)
        }
    }

    /// 迷いの検知: 手を止めた長さが十分にたまった段で、本人のリズムの待ち時間を試す（放置で続きを自動生成がオンのときだけ）。
    /// 試す前の 2 週間の、決まった秒数での採用率を覚えておき、試した後に下がったら元に戻す
    private func activateRhythm(learner: PersonalLearner, tuner: PersonalTuner, now: Double) {
        guard Config.NextTextCompletion().value, Config.NextTextCompletionIdle().value else {
            return
        }
        learner.flushPauses()
        let baseline = Self.acceptanceCounts(.idleDelay, reactions: learner.reactionTotals(since: now - PersonalTuner.window))
        for (level, histogram) in learner.pauseHistograms where histogram.total >= PersonalRhythm.minimumPauses {
            let counts = baseline[level] ?? (0, 0)
            let acceptance = counts.shown >= PersonalTuner.minimumShown ? Double(counts.accepted) / Double(counts.shown) : nil
            if tuner.activateRhythm(level: level, pauses: histogram.total, baselineAcceptance: acceptance, now: now) {
                let delay = PersonalRhythm.personalDelay(histograms: [histogram], quantile: PersonalRhythm.defaultQuantile) ?? 0
                learner.recordReaction(
                    kind: "rhythm_on", scene: nil, a: level, b: String(format: "%.2f", delay), n: acceptance.map { Int(($0 * 1000).rounded()) }
                )
                NSLog("llm-ime: idle rhythm trial at %@ (%.1fs, baseline %@)", level, delay, acceptance.map { String(format: "%.2f", $0) } ?? "-")
            }
        }
    }

    private func replay(learner: PersonalLearner, tuner: PersonalTuner, now: Date) {
        let samples = learner.replaySamples(since: now.timeIntervalSince1970 - PersonalTuner.window, limit: 400)
        guard samples.count >= PersonalTuner.minimumReplaySamples else {
            return
        }
        // 本番と同じ手本を付ける（その位置より前の文だけから選ぶ）
        let items = samples.map { sample in
            (context: sample.context, prefix: learner.completionPrefix(scene: sample.scene, context: sample.context, before: sample.ts))
        }
        self.replaying = true
        self.lastReplay = now
        self.commitsAtLastReplay = learner.commitCount
        let baselineStats = Self.completionStats(
            reactions: learner.reactionTotals(since: now.timeIntervalSince1970 - PersonalTuner.window),
            commits: learner.commitTotals(since: now.timeIntervalSince1970 - PersonalTuner.window)
        )
        Task { @MainActor in
            let result = await NextTextCompletionEngine.shared.replay(items, budget: PersonalTuner.replayBudget)
            self.replaying = false
            let outcomes = zip(samples, result.pieces).map { sample, pieces in
                PersonalTuner.ReplayOutcome(levels: PersonalTuner.levelKeys(for: sample.scene), pieces: pieces, gold: sample.gold)
            }
            let changed = result.cancelled ? [] : tuner.applyReplay(outcomes, baseline: { level in
                baselineStats[level].map { ($0.acceptance, $0.saved) }
            }, now: Date().timeIntervalSince1970)
            // 実行の記録（時間・打ち切り）。本人の文章は含まない
            learner.recordReaction(
                kind: "tuning_replay", scene: nil,
                a: result.cancelled ? "cancelled" : (result.timedOut ? "timedOut" : "done"),
                b: String(format: "%.1f", result.elapsed), n: result.pieces.count
            )
            NSLog("llm-ime: tuning replay %d/%d samples in %.1fs%@, changed %d levels", result.pieces.count, items.count, result.elapsed,
                  result.cancelled ? " (cancelled)" : "", changed.count)
        }
    }
}
