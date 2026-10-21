import Core
import Foundation
import Gemma4ANE
import LocalLLM
import AppKit

// MARK: - 解析と学習の実行（llm-ime、段階 A）
//
// 記録の写しを作って ShizukuLab（別のプロセス）を起動し、進み具合を見て、結果を確かめてから採用する。
// - 本人がキーを押した・いい感じ変換を使ったら、ShizukuLab をすぐ止める（SIGSTOP。CPU を使わない）。10 秒操作がなければ続ける（SIGCONT）
// - 時間の上限は動いている時間だけで数える。止まったままの時間が 2 時間を超えた・夜の時間が終わったら、打ち切って何も採用しない
// - 写しと置き場所には本人の文章が入るので、どう終わっても（失敗・打ち切りも）すぐ消す。起動時にも残りを消す
// - 採否は ShizukuLab の判定ではなく、項目ごとの差から LabRules で計算し直して決める。採用は版として残し、「元に戻す」で前の版に戻す
// - 学習がオフなら始めない（夜の自動実行もしない）。一度も採用していなければ値は既定（今と同じ）

@MainActor
final class LabController {
    static let shared = LabController()

    /// 動いている時間の上限・止まったままの上限・操作がなくなってから続けるまで
    static let runningBudget: TimeInterval = 3600
    static let stoppedCap: TimeInterval = 2 * 3600
    static let resumeAfterIdle: TimeInterval = 10
    /// 夜の自動実行: 週 1 回、1 時〜5 時、30 分以上操作がない
    static let nightlyInterval: TimeInterval = 7 * 86400
    static let nightlyHours = 1..<5
    static let nightlyIdle: TimeInterval = 30 * 60

    struct Summary: Codable {
        var date: Double
        var trigger: String
        var outcome: String
        var details: [String]
    }

    private var process: Process?
    private var usageURL: URL?
    private var usageGeneration = 0
    private var job: LabJobKind = .analysis
    private var upperBoundMessage = ""
    private(set) var personalizationRevision = 0
    private var knowledge: LabKnowledge?
    private var adapter: URL?
    private var adapterModel: LabModelStamp?

    private func refreshPersonalization() {
        self.personalizationRevision += 1
        let revision = self.personalizationRevision
        self.knowledge = nil; self.adapter = nil; self.adapterModel = nil
        PersonalLearner.shared.corpus.magicTopics = []
        Task { await LocalLLMEngine.shared.invalidatePersonalization() }
        let versions = self.versions
        Task {
            let assets = await Task.detached(priority: .utility) { () -> (LabKnowledge?, URL?, LabModelStamp?) in
                let knowledge = versions.currentAsset(.knowledge).flatMap { LabKnowledge.read(at: $0) }
                let adapter = versions.currentAsset(.adapter)
                let metadata = adapter.flatMap { LabAdapterMetadata.read(at: $0) }
                let valid = adapter.map { metadata?.validConfiguration(at: $0) == true && (metadata?.samples ?? 0) >= 2000 } ?? false
                return (knowledge, valid ? adapter : nil, metadata?.model)
            }.value
            guard self.personalizationRevision == revision else { return }
            let source = PersonalEmbeddingService.availableModelURL.flatMap { ModelCatalog.embeddingInfo(at: $0)?.source }
            let supported = assets.0.map { $0.model.matches(directory: ConverterServer.localLLMModelDirectory)
                && ($0.topics.isEmpty || $0.embeddingSource == source && source != nil) } ?? false
            self.knowledge = supported ? assets.0 : nil; self.adapter = assets.1; self.adapterModel = assets.2
            PersonalLearner.shared.corpus.magicTopics = self.knowledge?.topics ?? []
        }
    }

    func personalization(scene: PersonalScene?, vector: [Float]?, model: URL) -> (style: String?, adapter: URL?) {
        guard PersonalLearner.isEnabled, let scene else { return (nil, nil) }
        let style = self.knowledge?.model.matches(directory: model) == true ? self.knowledge?.instruction(scene: scene, vector: vector) : nil
        return (style, self.adapterModel?.matches(directory: model) == true ? self.adapter : nil)
    }

    func learningDisabled() {
        self.stop(reason: "学習がオフになったため")
        self.refreshPersonalization()
    }

    func modelChanged() {
        self.stop(reason: "ローカルモデルの設定が変わったため")
        self.refreshPersonalization()
    }

    func exportAssets(beside url: URL) throws {
        var folder = url.deletingPathExtension().appendingPathExtension("learning")
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = url.deletingPathExtension().appendingPathExtension("learning-\(suffix)")
            suffix += 1
        }
        try self.versions.export(to: folder)
    }

    /// 二つの GPU モデルを同時に置かない。入力用の呼出しは Lab の終了を確認してから読み込む。
    func prepareForLocalModel() async {
        guard let process = self.process else { return }
        self.stop(reason: "ローカルモデルを使うため")
        for _ in 0..<100 {
            if !process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    private var runID = ""
    private var snapshotID = ""
    private var split = 0.0
    /// 実行に渡した今の値（結果の今の値がこれと同じときだけ採用する）
    private var baseline = LabParameters.defaults
    private var runDirectory: URL?
    private var trigger = ""
    private var runningSeconds: TimeInterval = 0
    private var lastTick = Date()
    private var stoppedSince: Date?
    private var lastActivity = Date.distantPast
    private var windowEnd: Date?
    private var monitor: Timer?
    private var terminationReason: String?
    private(set) var progress: LabProgress?
    /// キーを受けてから ShizukuLab が止まったと見えるまで（ミリ秒。直近 50 回。止まったと見えなかったら nil）
    private(set) var stopLatencies: [Double?] = []

    var isRunning: Bool {
        self.process != nil || self.runDirectory != nil
    }

    var isStopped: Bool {
        self.stoppedSince != nil
    }

    private var labDirectory: URL {
        PersonalLearner.directoryURL.appendingPathComponent("lab", isDirectory: true)
    }

    private var runsDirectory: URL {
        self.labDirectory.appendingPathComponent("runs", isDirectory: true)
    }

    private var summaryURL: URL {
        self.labDirectory.appendingPathComponent("last.json")
    }

    private var upperBoundURL: URL {
        self.labDirectory.appendingPathComponent("last-upper-bound.json")
    }

    var versions: LabVersionStore {
        LabVersionStore(directory: self.labDirectory)
    }

    private var labExecutableURL: URL? {
        guard let server = Bundle.main.executableURL else {
            return nil
        }
        let url = server.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ShizukuLab", isDirectory: true).appendingPathComponent("ShizukuLab")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: 起動・設定

    /// 起動時: 前の実行の残り（写し・置き場所）を消し、今の版の値を入れる
    func startup() {
        try? FileManager.default.removeItem(at: self.runsDirectory)
        LabParameters.apply(self.versions.appliedParameters)
        self.refreshPersonalization()
        PersonalLearner.shared.onRetentionPruned = { cutoff in
            if self.versions.allVersions().contains(where: { !$0.gatedArtifacts.isEmpty && ($0.dataFrom ?? 0) < cutoff }) {
                self.dataForgotten(all: false)
            } else {
                try? FileManager.default.removeItem(at: self.labDirectory.appendingPathComponent("last-report.json"))
            }
        }
        // 通しの確かめ（確かめ用の記録の場所を使っているときだけ）: 意味の近さの重みを入れて、手本選びの流れを確かめる（版には残さない）
        if PersonalLearner.isUsingTestStore, let weight = ProcessInfo.processInfo.environment["LLM_IME_E2E_SEMANTIC_WEIGHT"].flatMap(Double.init) {
            var parameters = self.versions.appliedParameters
            parameters.semanticWeight = weight
            if parameters.isWithinBounds {
                LabParameters.apply(parameters)
            }
        }
    }

    var summary: Summary? {
        (try? Data(contentsOf: self.summaryURL)).flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
    }

    private func saveSummary(_ outcome: String, details: [String]) {
        let summary = Summary(date: Date().timeIntervalSince1970, trigger: self.trigger, outcome: outcome, details: details)
        try? FileManager.default.createDirectory(at: self.labDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(summary).write(to: self.summaryURL, options: .atomic)
    }

    /// 記録の量の下限（ShizukuLab と同じ）。足りなければ「あと N 文」の N
    func shortfall() -> Int {
        let counts = PersonalLearner.shared.labDataCounts()
        return max(0, 200 - counts.heldOut) + max(0, 200 - counts.validation)
    }

    // MARK: 開始・止める

    /// 始める。始められなければ理由を返す
    @discardableResult
    func start(trigger: String, windowEnd: Date? = nil, job: LabJobKind = .analysis) -> String? {
        guard PersonalLearner.isEnabled else {
            return "学習がオフ"
        }
        guard !self.isRunning else {
            return "実行中"
        }
        if job == .upperBound && !ResourceBudget.current.replay { return "資源の段により再生を停止" }
        if job == .analysis && !ConverterServer.localModelAllowed { return "現在の資源の段では解析モデルを自動選択しません" }
        // 上限は全確定の時刻順再生で測るため、学習用・取り置きの境目は使わない。
        let short = job == .upperBound ? max(0, 10 - PersonalLearner.shared.commitCount) : self.shortfall()
        guard short == 0 else {
            return "記録が足りない（あと \(short) 文）"
        }
        guard let executable = self.labExecutableURL else {
            return "ShizukuLab が見つからない"
        }
        guard let last = PersonalLearner.shared.labDataCounts().lastCommit else {
            return "記録がない"
        }
        let id = UUID().uuidString
        let directory = self.runsDirectory.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return "置き場所を作れない"
        }
        self.runID = id
        self.job = job
        if job == .upperBound { self.upperBoundMessage = "" }
        self.snapshotID = UUID().uuidString
        if job == .analysis { self.split = LabSplit.make(lastCommit: last).split }
        self.runDirectory = directory
        self.trigger = trigger
        self.windowEnd = windowEnd
        self.runningSeconds = 0
        self.stoppedSince = nil
        self.terminationReason = nil
        self.progress = LabProgress(stage: "snapshot", fraction: 0, note: "記録の写しを作る")
        let snapshot = directory.appendingPathComponent("snapshot.sqlite")
        PersonalLearner.shared.snapshot(to: snapshot) { [weak self] ok in
            guard let self, self.runDirectory == directory else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            guard ok, self.terminationReason == nil else {
                self.finish(exitStatus: -1, note: self.terminationReason ?? "記録の写しを作れなかった")
                return
            }
            Task {
                let busy = await LocalLLMEngine.shared.isBusy
                guard self.runDirectory == directory, self.terminationReason == nil else { return }
                guard !busy else {
                    self.finish(exitStatus: -1, note: "入力用のローカルモデルが処理中のため")
                    return
                }
                await LocalLLMEngine.shared.unload()
                guard self.runDirectory == directory, self.terminationReason == nil else { return }
                self.launch(executable: executable, snapshot: snapshot, directory: directory)
            }
        }
        return nil
    }

    private func launch(executable: URL, snapshot: URL, directory: URL) {
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        if self.job == .upperBound {
            let arguments = ["upper-bound", "--snapshot", snapshot.path, "--resources", ConverterServer.appResourcesDirectoryURL().path,
                             "--out", staging.appendingPathComponent("result.json").path,
                             "--completion-model", NextTextCompletionEngine.modelDirectoryURL(powerSaving: Config.NextTextCompletionPowerSaving().value).path]
            self.launchProcess(executable: executable, arguments: arguments)
            return
        }
        self.baseline = self.versions.appliedParameters
        var arguments = [
            "run", "--snapshot", snapshot.path, "--snapshot-id", self.snapshotID, "--run-id", self.runID, "--split", String(self.split),
            "--staging", staging.path, "--resources", ConverterServer.appResourcesDirectoryURL().path,
            "--baseline", String(decoding: self.baseline.canonicalJSON(), as: UTF8.self),
            "--seed", String(LabRules.seed),
        ]
        let local = ConverterServer.localLLMModelDirectory
        let embeddingSource = PersonalEmbeddingService.availableModelURL.flatMap { ModelCatalog.embeddingInfo(at: $0)?.source }
        if LocalLLMEngine.isModelInstalled(at: local) {
            arguments += ["--local-model", local.path, "--style", Config.MagicConversionStyle().value]
            if let url = self.versions.currentAsset(.knowledge), let knowledge = LabKnowledge.read(at: url), knowledge.model.matches(directory: local),
               knowledge.topics.isEmpty || knowledge.embeddingSource == embeddingSource && embeddingSource != nil {
                arguments += ["--knowledge", url.path]
            }
            if let url = self.versions.currentAsset(.adapter), let metadata = LabAdapterMetadata.read(at: url), metadata.samples >= 2000,
               metadata.validConfiguration(at: url), metadata.model.matches(directory: local) {
                arguments += ["--adapter", url.path]
            }
        }
        if let embedding = PersonalEmbeddingService.availableModelURL { arguments += ["--embedding-model", embedding.path] }
        // 続き予測が E2B なら、続き予測の答え合わせはしない（自己調整と同じく本人の判断）
        let completionModel = NextTextCompletionEngine.modelDirectoryURL(powerSaving: Config.NextTextCompletionPowerSaving().value)
        if PersonalTuner.isPowerSavingModel(completionModel) {
            arguments += ["--skip-completion", "続き予測のモデルが E2B（E2B では答え合わせを走らせない）"]
        } else if !Config.NextTextCompletion().value {
            arguments += ["--skip-completion", "続き予測がオフ"]
        } else {
            arguments += ["--completion-model", completionModel.path]
        }
        self.launchProcess(executable: executable, arguments: arguments)
    }

    private func launchProcess(executable: URL, arguments: [String]) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let usage = self.runDirectory!.appendingPathComponent("resource-ms.json")
        self.usageURL = usage
        self.usageGeneration = PersonalLearner.shared.forgetGeneration
        var environment = ProcessInfo.processInfo.environment
        environment["SHIZUKU_INFERENCE_USAGE"] = usage.path
        process.environment = environment
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                LabController.shared.finish(exitStatus: status, note: nil)
            }
        }
        do {
            try process.run()
        } catch {
            self.finish(exitStatus: -1, note: "ShizukuLab を起動できなかった")
            return
        }
        self.process = process
        self.lastTick = Date()
        self.monitor?.invalidate()
        self.monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                LabController.shared.tick()
            }
        }
    }

    /// 止める（本人の操作・時間切れ・データの削除）。何も採用しない
    func stop(reason: String) {
        guard self.isRunning else {
            return
        }
        self.terminationReason = reason
        if let process = self.process {
            kill(process.processIdentifier, SIGTERM)
            // 止めている（SIGSTOP）ままだと SIGTERM が届かないので、続けさせてから終わらせる
            kill(process.processIdentifier, SIGCONT)
        }
    }

    // MARK: 本人の操作で止める

    /// キーを押した（主スレッド。キーの処理の最初に呼ぶ）
    func noteActivity() {
        self.lastActivity = Date()
        guard let process = self.process, self.stoppedSince == nil else {
            return
        }
        let start = DispatchTime.now()
        if ["lora", "magic", "analyst"].contains(self.progress?.stage ?? "") {
            self.stop(reason: "入力が始まったため（大きいモデルは空いている時間に再実行できます）")
            return
        }
        let pid = process.processIdentifier
        kill(pid, SIGSTOP)
        self.stoppedSince = Date()
        // 本当に止まったか（カーネルの状態が SSTOP になるまで）を裏で測る（キーの処理は待たない）
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
            var stopped = false
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if Self.isStopped(pid) {
                    stopped = true
                    break
                }
                usleep(100)
            }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Task { @MainActor in
                LabController.shared.stopLatencies = Array((LabController.shared.stopLatencies + [stopped ? milliseconds : nil]).suffix(50))
            }
        }
    }

    /// プロセスが止まっている（SIGSTOP で SSTOP）か
    nonisolated static func isStopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        return info.kp_proc.p_stat == SSTOP
    }

    /// いい感じ変換を使う（段階 C・D で ShizukuLab が大きいモデルを持っているなら、2 つ目を読み込まないよう ShizukuLab を終わらせる）
    func noteMagicConversion(labHoldsLargeModel: Bool = false) {
        if labHoldsLargeModel {
            self.stop(reason: "いい感じ変換を使うため")
        } else {
            self.noteActivity()
        }
    }

    private func tick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(self.lastTick)
        self.lastTick = now
        if let directory = self.runDirectory {
            let progressURL = directory.appendingPathComponent("staging/progress.jsonl")
            if let text = try? String(contentsOf: progressURL, encoding: .utf8),
               let last = text.split(separator: "\n").last,
               let progress = try? JSONDecoder().decode(LabProgress.self, from: Data(last.utf8)) {
                self.progress = progress
            }
        }
        guard let process = self.process else {
            return
        }
        if let stoppedSince = self.stoppedSince {
            if now.timeIntervalSince(self.lastActivity) >= Self.resumeAfterIdle {
                kill(process.processIdentifier, SIGCONT)
                self.stoppedSince = nil
            } else if now.timeIntervalSince(stoppedSince) > Self.stoppedCap {
                self.stop(reason: "止まったままの時間が長すぎる")
            }
        } else {
            self.runningSeconds += elapsed
            if self.runningSeconds > Self.runningBudget {
                self.stop(reason: "時間の上限")
            }
        }
        if let windowEnd = self.windowEnd, now > windowEnd {
            self.stop(reason: "夜の時間が終わった")
        }
    }

    // MARK: 終わったとき

    private func finish(exitStatus: Int32, note: String?) {
        if let usage = self.usageURL {
            if self.usageGeneration == PersonalLearner.shared.forgetGeneration,
               let data = try? Data(contentsOf: usage), let events = try? JSONDecoder().decode([InferenceActivity.Event].self, from: data) {
                for event in events { PersonalLearner.shared.recordResourceUsage(feature: event.feature, device: event.device, milliseconds: event.milliseconds) }
            }
            try? FileManager.default.removeItem(at: usage)
            self.usageURL = nil
        }
        self.monitor?.invalidate()
        self.monitor = nil
        self.process = nil
        defer {
            // 写しと置き場所（本人の文章）を必ず消す
            if let directory = self.runDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
            self.runDirectory = nil
            self.stoppedSince = nil
            self.windowEnd = nil
        }
        let resultData = self.runDirectory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("staging/result.json")) }
        self.job.finish(upperBound: {
            // この経路では LabOutcome・LabParameters・版・手本・自動辞書へ渡さない。
            guard self.terminationReason == nil, note == nil, exitStatus == 0, let resultData,
                  let result = try? JSONDecoder().decode(LabUpperBound.Report.self, from: resultData), result.schema == 1,
                  let safeData = try? result.canonicalJSON() else {
                self.upperBoundMessage = "履歴の測定は完了しませんでした。前回の測定は保持しています。"
                return
            }
            do {
                try FileManager.default.createDirectory(at: self.labDirectory, withIntermediateDirectories: true)
                try safeData.write(to: self.upperBoundURL, options: .atomic)
                self.upperBoundMessage = ""
            } catch {
                self.upperBoundMessage = "履歴の測定結果を保存できませんでした。"
            }
        }, analysis: {
            self.finishAnalysis(exitStatus: exitStatus, note: note, resultData: resultData)
        })
    }

    private func finishAnalysis(exitStatus: Int32, note: String?, resultData: Data?) {
        let outcome = LabOutcome.decide(
            exitStatus: exitStatus, stopReason: self.terminationReason ?? note, resultData: resultData,
            runID: self.runID, snapshotID: self.snapshotID, split: self.split, baseline: self.baseline
        )
        func details(_ result: LabRunResult) -> [String] {
            result.notes + result.skipped + ["記録 \(result.counts["commits"] ?? 0) 件（答え合わせ \(result.counts["heldOutConversion"] ?? 0) 件）"]
        }
        if self.terminationReason == nil, exitStatus == 0, let resultData,
           let result = try? JSONDecoder().decode(LabRunResult.self, from: resultData), result.runID == self.runID,
           result.snapshotID == self.snapshotID, result.split == self.split, let directory = self.runDirectory,
           let report = result.artifacts.first(where: { $0.kind == .report }),
           report.verified(root: directory.appendingPathComponent("staging"), split: self.split) {
            try? Data(contentsOf: directory.appendingPathComponent("staging/report.json"))
                .write(to: self.labDirectory.appendingPathComponent("last-report.json"), options: .atomic)
        }
        switch outcome {
        case .stopped(let reason):
            self.saveSummary("止めました（\(reason)）。何も採用していません", details: [])
        case .failed:
            self.saveSummary("解析が途中で終わりました。何も採用していません", details: [])
        case .insufficient(let result):
            self.saveSummary("記録が足りないため、何も変えていません", details: details(result))
        case .noCandidate(let result):
            self.saveSummary("今の設定より良い案は見つかりませんでした", details: details(result))
        case .rejected(let result, let reasons):
            self.saveSummary("案は答え合わせを通らなかったため、採用していません", details: details(result) + reasons)
        case .adopt(let result, let candidate, let decision):
            do {
                guard let directory = self.runDirectory else { throw LabError.invalidResult("成果物の置き場所がない") }
                let staging = directory.appendingPathComponent("staging")
                for artifact in result.artifacts {
                    if artifact.kind == .knowledge {
                        guard let knowledge = LabKnowledge.read(at: staging.appendingPathComponent(artifact.name)),
                              knowledge.model.matches(directory: ConverterServer.localLLMModelDirectory) else { throw LabError.invalidResult("文体の対応モデルが合わない") }
                    } else if artifact.kind == .adapter {
                        guard let metadata = LabAdapterMetadata.read(at: staging.appendingPathComponent(artifact.name)), metadata.isWithinBounds,
                              metadata.samples >= 2000, metadata.validConfiguration(at: staging.appendingPathComponent(artifact.name)),
                              metadata.model.matches(directory: ConverterServer.localLLMModelDirectory) else { throw LabError.invalidResult("アダプタの学習条件またはモデルが合わない") }
                    }
                }
                try self.versions.adopt(result: result, candidate: candidate, decision: decision, staging: staging, note: self.trigger)
                LabParameters.apply(candidate)
                self.refreshPersonalization()
                let gains = decision.intervals.sorted { $0.key < $1.key }.map { metric, interval in
                    String(format: "%@ %+.4f（95%%: %+.4f〜%+.4f、%d 件）", metric, interval.mean, interval.lower, interval.upper, interval.count)
                }
                self.saveSummary("答え合わせで良くなった設定を採用しました（元に戻せます）", details: details(result) + gains)
            } catch {
                self.saveSummary("採用できませんでした（\(error)）", details: details(result))
            }
        }
    }

    // MARK: 元に戻す・データの削除

    func undo() {
        _ = try? self.versions.undo()
        LabParameters.apply(self.versions.appliedParameters)
        self.refreshPersonalization()
        self.saveSummary("前の版に戻しました", details: [])
    }

    /// 記録が消された（アプリごと・全部）: 実行中なら止め、写しを消し、文章から作ったものを無効にする。全部なら版も消す
    func dataForgotten(all: Bool) {
        self.stop(reason: "記録が消されたため")
        try? FileManager.default.removeItem(at: self.runsDirectory)
        if all {
            try? self.versions.removeAll()
            try? FileManager.default.removeItem(at: self.summaryURL)
        } else {
            try? self.versions.invalidateTextArtifacts()
        }
        LabParameters.apply(self.versions.appliedParameters)
        try? FileManager.default.removeItem(at: self.summaryURL)
        try? FileManager.default.removeItem(at: self.upperBoundURL)
        self.refreshPersonalization()
    }

    // MARK: 夜の自動実行

    /// 10 分ごとに呼ぶ。週 1 回、夜、電源につながっていて、30 分以上操作がなく、熱の状態が通常なら始める
    func considerNightly(now: Date, secondsSinceLastKey: TimeInterval, onACPower: Bool) {
        guard ResourceBudget.current.replay, Config.LabNightly().value, PersonalLearner.isEnabled, !self.isRunning, onACPower,
              secondsSinceLastKey >= Self.nightlyIdle, ProcessInfo.processInfo.thermalState == .nominal,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            return
        }
        let calendar = Calendar.current
        guard Self.nightlyHours.contains(calendar.component(.hour, from: now)) else {
            return
        }
        if let summary = self.summary, now.timeIntervalSince1970 - summary.date < Self.nightlyInterval {
            return
        }
        let windowEnd = calendar.date(bySettingHour: Self.nightlyHours.upperBound, minute: 0, second: 0, of: now)
        self.start(trigger: "夜の自動実行", windowEnd: windowEnd)
    }

    // MARK: 設定画面

    func descriptors(inspection: Bool = false) -> [ConverterSettingDescriptor] {
        let section = "解析と学習"
        let status: String
        if self.isRunning {
            let stage = self.progress.map { "\($0.stage) \(Int($0.fraction * 100))%" } ?? "準備中"
            status = self.isStopped ? "一時停止中（入力中のため）・\(stage)" : "実行中・\(stage)"
        } else if !PersonalLearner.isEnabled {
            status = "学習がオフのため使えません"
        } else {
            let short = self.shortfall()
            status = short > 0 ? "記録が足りません（あと \(short) 文）" : "開始できます"
        }
        var summaryText = "まだ実行していません"
        if let summary = self.summary {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            summaryText = "\(formatter.string(from: Date(timeIntervalSince1970: summary.date)))（\(summary.trigger)）: \(summary.outcome)"
                + (summary.details.isEmpty ? "" : "\n" + summary.details.joined(separator: "\n"))
        }
        let canStart = PersonalLearner.isEnabled && !self.isRunning && self.shortfall() == 0
        let canMeasure = PersonalLearner.isEnabled && !self.isRunning && PersonalLearner.shared.commitCount >= 10
        let measurement = (try? Data(contentsOf: self.upperBoundURL)).flatMap { try? JSONDecoder().decode(LabUpperBound.Report.self, from: $0) }
        let measurementText = (self.upperBoundMessage.isEmpty ? "" : self.upperBoundMessage + "\n")
            + (measurement?.summary ?? "履歴の上限はまだ測っていません（10件以上の記録が必要）。oracle は上限であり、実装できる性能ではありません。")
        // 現行クライアントが表示する既存の要約にも載せる（新しいキーだけでは画面に出ない）。
        summaryText += "\n履歴の上限:\n" + measurementText
        if let data = try? Data(contentsOf: self.labDirectory.appendingPathComponent("last-report.json")),
           let report = try? JSONDecoder().decode(LabAnalysisReport.self, from: data) {
            summaryText += "\n" + report.summary + "\n" + report.loraNote
                + String(format: "\n選ぶ用の F1: %.4f → %.4f", report.baselineF1 ?? 0, report.selectedF1 ?? 0)
                + "\n道具の記録: " + report.calls.map { "\($0.tool)（\($0.accepted ? "実行" : "拒否")）" }.joined(separator: " → ")
        }
        let measured = self.stopLatencies.compactMap { $0 }.sorted()
        let diagnostics = (measured.isEmpty ? "止めた記録なし" : String(
            format: "キーから止まるまで 中央値 %.2fms・最大 %.2fms（%d 回、止まらなかった %d 回）",
            measured[measured.count / 2], measured.last ?? 0, measured.count, self.stopLatencies.count - measured.count
        )) + "／" + PersonalEmbeddingService.shared.diagnostics
        var result: [ConverterSettingDescriptor] = [
            .init(key: Config.labStatusKey, title: status, section: section, kind: .textField(secure: false), value: .string(""), isEnabled: false),
            .init(key: Config.labStartKey, title: "解析と学習を開始", section: section, kind: .toggle, value: .bool(false), isEnabled: canStart),
            .init(key: Config.labUpperBoundKey, title: "履歴の上限を測る", section: section, kind: .toggle, value: .bool(false), isEnabled: canMeasure),
            .init(key: Config.labUpperBoundSummaryKey, title: measurementText, section: section, kind: .textField(secure: false), value: .string(""), isEnabled: false),
            .init(key: Config.labStopKey, title: "止める", section: section, kind: .toggle, value: .bool(false), isEnabled: self.isRunning),
            .init(key: Config.LabNightly.key, title: "週 1 回、夜に自動で行う", section: section, kind: .toggle, value: .bool(Config.LabNightly().value)),
            .init(key: Config.labSummaryKey, title: summaryText, section: section, kind: .textField(secure: false), value: .string(""), isEnabled: false),
            .init(key: Config.labReportKey, title: "解析と道具の記録を表示", section: section, kind: .toggle, value: .bool(false),
                  isEnabled: FileManager.default.fileExists(atPath: self.labDirectory.appendingPathComponent("last-report.json").path)),
            .init(key: Config.labUndoKey, title: "元に戻す（版 \(self.versions.currentVersion)）", section: section, kind: .toggle, value: .bool(false),
                  isEnabled: self.versions.currentVersion > 0 && !self.isRunning),
            .init(key: Config.labDiagnosticsKey, title: diagnostics, section: section + ":確かめ用", kind: .textField(secure: false),
                  value: .string(""), isEnabled: false),
        ]
        if inspection {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var checked = LabUpperBound.inspection(directory: self.labDirectory, running: self.isRunning)
            checked.usesTestStore = PersonalLearner.isUsingTestStore
            checked.testStoreExists = FileManager.default.fileExists(atPath: PersonalLearner.groupTestStoreDirectory.path)
            let data = measurement.flatMap { try? $0.canonicalJSON() } ?? Data()
            result += [
                .init(key: Config.labUpperBoundDataKey, title: "履歴の上限の数値JSON（文章なし）", section: section + ":確かめ用",
                      kind: .textField(secure: false), value: .string(String(decoding: data, as: UTF8.self)), isEnabled: false),
                .init(key: Config.labUpperBoundInspectionKey, title: "履歴の上限の検証用の数とハッシュ", section: section + ":確かめ用",
                      kind: .textField(secure: false), value: .string(String(decoding: (try? encoder.encode(checked)) ?? Data(), as: UTF8.self)), isEnabled: false),
            ]
        }
        return result
    }

    /// 設定の操作。扱ったら true
    func update(key: String, value: ConverterSettingValue) -> Bool {
        switch key {
        case Config.labStartKey:
            self.start(trigger: "ボタン")
        case Config.labUpperBoundKey:
            self.start(trigger: "履歴の上限の測定", job: .upperBound)
        case Config.labStopKey:
            self.stop(reason: "本人が止めた")
        case Config.labUndoKey:
            self.undo()
        case Config.labReportKey:
            NSWorkspace.shared.open(self.labDirectory.appendingPathComponent("last-report.json"))
        case Config.LabNightly.key:
            if case .bool(let enabled) = value {
                Config.LabNightly().value = enabled
            }
        default:
            return false
        }
        return true
    }
}
