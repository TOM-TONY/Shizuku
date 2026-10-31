import Core
import CoreGraphics
import Foundation
import LocalLLM
import os

// MARK: - 次の依頼の予想（llm-ime）
//
// AI とのチャット・ターミナルで、画面の返信先（AI の最後の返答）が変わって落ち着いたら、ローカル LLM（12B / 31B）で
// 本人が次に送りそうな依頼を 1 文先に作っておく。生成に数秒かかるため、空の欄で手を止めたときには出来上がっているようにする。
// 出すのは Client が尋ねたときだけで、そのときも画面の返信先が作ったときと同じ場合に限る。画面の文章は保存・記録しない。

@MainActor
final class NextPromptService {
    static let shared = NextPromptService()

    private struct Entry {
        let app: String
        let fingerprint: Int
        /// 作ったときの返信先（画面にまだ出ているかを確かめるため。メモリの中だけ）
        let reply: String
        var text: String?
        var finished = false
        var task: Task<Void, Never>?
    }
    /// 空の欄で尋ねられたときの答え
    enum State: Equatable {
        case ready(String)
        /// 返答が落ち着くのを待っている・作っている（Client は尋ね直す）
        case pending
        /// 作らない（AI との会話でない・返信先がない・作れなかった）
        case none
    }
    private var stability = NextPrompt.Stability()
    private var entry: Entry?
    /// 返信先が変わっている（AI が書いている）のを最後に見た時刻とアプリ
    private var settling: (app: String, at: Date)?
    static let settlingWindow: TimeInterval = 20

    private init() {}

    /// 「放置時に本文を生成」の中の設定。ウィンドウの参照も要る
    var enabled: Bool {
        Config.NextPromptSuggestion().value && Config.WindowContextEnabled().value
            && Config.NextTextCompletion().value && Config.NextTextCompletionIdle().value
    }

    /// AI への入力の場面か（場所が分かるブラウザでは、本人がその欄で打った後の場面で判断する）
    nonisolated static func applies(app: String, scene: PersonalScene?) -> Bool {
        PersonalScene.aiApps.contains(app) || PersonalPrivacy.terminalApps.contains(app)
            || (scene?.app == app && scene?.aiDirected == true)
    }

    /// 画面の読み取りのたびに呼ぶ（WindowContextService.publish）。返信先が変わって落ち着いたら生成を始める
    func observe(_ reference: WindowReference, binding: WindowContextBinding, session: ConverterSession?) {
        guard self.enabled else { return }
        guard let session, session.manager.isEmpty else { return self.note("observe: composing or no session") }
        guard Self.applies(app: binding.app, scene: session.personal.scene) else { return self.note("observe: not an AI scene") }
        let terminal = PersonalPrivacy.terminalApps.contains(binding.app)
        // 欄に書きかけの文章があれば、次の依頼は要らない（カーソルより前に文字があるときだけ。欄の文字数は案内文を数えるアプリがある）
        let before = (reference.fieldBefore ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !terminal, !before.isEmpty {
            return self.note("observe: field has text (empty=\(reference.fieldEmpty.map(String.init) ?? "unknown") before=\(before.count))")
        }
        guard let source = NextPrompt.source(reference, terminal: terminal) else {
            return self.note("observe: no reply target (blocks=\(reference.blocks.count) editing=\(reference.editing.height > 0))")
        }
        if let entry, entry.app == binding.app, entry.fingerprint == source.fingerprint { return }
        guard self.stability.observe(source.fingerprint, now: Date().timeIntervalSince1970) else {
            self.settling = (binding.app, Date())
            return self.note("observe: reply changing (blocks=\(reference.blocks.count) reply=\(source.reply.count))")
        }
        guard AssistanceSettings.permits(.idle, app: binding.app), !PersonalPrivacy.isExcluded(app: binding.app) else {
            return self.note("observe: not permitted for this app")
        }
        guard ConverterServer.localModelAllowed else { return self.note("observe: local model not allowed") }
        guard !PersonalSensing.shared.microphoneActive else { return self.note("observe: microphone active") }
        self.entry?.task?.cancel()
        var scene = session.personal.scene
        if scene?.app != binding.app { scene = nil }
        let examples = PersonalLearner.isEnabled
            ? scene.map { PersonalLearner.shared.corpus.styleExamples(query: String(source.reply.suffix(60)), scene: $0, excluding: "") } ?? []
            : []
        let app = binding.app, fingerprint = source.fingerprint
        self.note("generate: start (reply=\(source.reply.count) earlier=\(source.earlier.count) examples=\(examples.count))")
        let task = Task { @MainActor [weak self] in
            defer { if self?.entry?.fingerprint == fingerprint { self?.entry?.finished = true } }
            // 本人が明示した書き直しなどを待たせない
            guard await !LocalLLMEngine.shared.isBusy, !Task.isCancelled else {
                self?.note("generate: skipped (engine busy)"); return
            }
            await LabController.shared.prepareForLocalModel()
            guard !Task.isCancelled else { return }
            let began = Date()
            let output: String?
            do {
                output = try await LocalLLMEngine.shared.respond(
                    system: NextPrompt.system,
                    user: NextPrompt.userPrompt(source, examples: examples),
                    modelDirectory: ConverterServer.localLLMModelDirectory,
                    maxTokens: 96,
                    thinking: false, usageFeature: "next-prompt"
                )
            } catch {
                output = nil
                self?.note("generate: failed (\(String(describing: type(of: error))))")
            }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(began))
            guard !Task.isCancelled, let self, self.entry?.app == app, self.entry?.fingerprint == fingerprint else {
                self?.note("generate: discarded after \(seconds)s (reply changed)"); return
            }
            guard let output else { return }
            guard let text = NextPrompt.clean(output) else {
                return self.note("generate: rejected after \(seconds)s (format, output=\(output.count))")
            }
            guard NextPrompt.permits(text, source: source) else {
                return self.note("generate: rejected after \(seconds)s (numbers or copy)")
            }
            self.entry?.text = PersonalLearner.shared.normalizedGeneratedText(text, scene: scene, route: .idle)
            self.note("generate: ready after \(seconds)s (text=\(text.count))")
        }
        self.entry = Entry(app: app, fingerprint: fingerprint, reply: source.reply, task: task)
    }

    private static let log = Logger(subsystem: "dev.tomonari.inputmethod.Shizuku", category: "nextPrompt")
    private var lastNote: String?
    /// 診断の記録。件数と理由だけで、画面や生成の文章は書かない。同じ理由は続けて書かない
    func note(_ message: String) {
        guard message != self.lastNote else { return }
        self.lastNote = message
        Self.log.notice("\(message, privacy: .public)")
    }

    /// 今の画面に対して作っておいた依頼。作った返答がまだ画面にあり、その後に別の返答が出ていなければ使う
    func state(for reference: WindowReference?, app: String, scene: PersonalScene?) -> State {
        guard self.enabled, Self.applies(app: app, scene: scene) else { return .none }
        let current = reference.flatMap { NextPrompt.source($0, terminal: PersonalPrivacy.terminalApps.contains(app)) }
        if let entry, entry.app == app, let reference {
            let newer = current.map { $0.fingerprint != entry.fingerprint && $0.reply.count >= NextPrompt.sentenceLength
                && !NextPrompt.related($0.reply, entry.reply) } ?? false
            if !newer, NextPrompt.isShown(entry.reply, in: reference) {
                if let text = entry.text { return .ready(text) }
                if !entry.finished { return .pending }
            }
        }
        if let settling, settling.app == app, Date().timeIntervalSince(settling.at) < Self.settlingWindow { return .pending }
        // 返信先があって、まだ作っていない（落ち着くのを待つ・読み取りを待つ）
        if let current, self.entry?.fingerprint != current.fingerprint { return .pending }
        return .none
    }

    /// 画面のロック・参照の停止・設定の変更で、作っておいた依頼を捨てる
    func reset() {
        self.entry?.task?.cancel()
        self.entry = nil
        self.settling = nil
        self.stability.reset()
    }
}

extension ConverterServer {
    /// 空の欄で手を止めたときの提案。AI との会話では次の依頼、それ以外（作れなかったときも）はいつもの書き出し。
    /// pending は次の依頼をまだ作っているとき。anchor は画面の読み取りから求めた欄の先頭の行（画面座標・左下原点）
    @MainActor
    func emptyFieldSuggestion(session: ConverterSession, observation: ConverterSceneObservation, round: Int) async
        -> (text: String?, pending: Bool, fromScreen: Bool, anchor: CGRect?) {
        let service = NextPromptService.shared
        guard session.manager.isEmpty, observation.documentLength.map({ $0 == 0 }) ?? true,
              let app = observation.bundleID, !PersonalPrivacy.isExcluded(app: app) else {
            service.note("ask: not applicable"); return (nil, false, false, nil)
        }
        let scene = session.personal.scene?.app == app ? session.personal.scene : nil
        var reference: WindowReference?
        if service.enabled, Self.isAIInput(app: app, scene: scene) {
            WindowContextService.shared.prepare(session.windowBinding, session: session)
            let generation = session.windowReferenceGeneration
            if let current = session.windowReference, session.windowBinding?.app == app,
               await WindowContextService.shared.isCurrent(session, generation: generation) {
                reference = current
            }
        }
        let anchor = reference.flatMap { Self.screenLineRect(editing: $0.editing) }
        switch service.state(for: reference, app: app, scene: scene) {
        case .pending:
            service.note("ask: pending (reference=\(reference != nil))")
            return (nil, true, false, anchor)
        case .ready(let text):
            // 欄の長さを返さないアプリでは、画面の読み取りで欄が空と分かったときだけ出す。
            // 文字数は案内文を数えるアプリがあるので、カーソルより前が空なら空とみなす
            let before = (reference?.fieldBefore ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard observation.documentLength != nil || before.isEmpty else {
                service.note("ask: field has text on screen"); return (nil, false, false, nil)
            }
            guard session.manager.isEmpty, !PersonalSensing.shared.muteGeneration(kind: "idle", scene: scene),
                  self.automaticOfferAllowed(.idle, session: session, scene: scene), session.offers.mayPrepare(.idle) else {
                service.note("ask: offer not allowed"); return (nil, false, false, nil)
            }
            session.idleUsedReference = true
            let offered = self.emptyOffer(.idle, text: text, session: session, scene: scene)
            service.note(offered == nil ? "ask: dismissed or arbitrated away" : "ask: offered next prompt")
            return (offered, false, offered != nil, anchor)
        case .none:
            break
        }
        // 次の依頼を出さない場面は、いつもの書き出し（欄が空と分かるときだけ。記録は最初に尋ねたときだけ）
        guard observation.documentLength == 0 else { return (nil, false, false, anchor) }
        if round == 0, PersonalLearner.isRecording, !PersonalPrivacy.isExcluded(app: app) {
            self.noteStallEntry(session: session)
        }
        return (await self.personalSkeleton(session: session, observation: observation), false, false, anchor)
    }

    /// AI への入力の場面か（Client が送った場面の観測から。ブラウザは本人が打った後の場面）
    static func isAIInput(app: String, scene: PersonalScene?) -> Bool {
        NextPromptService.applies(app: app, scene: scene)
    }

    /// 画面の読み取りの欄の矩形（AX の座標。左上原点）から、欄の先頭の行の矩形（画面座標・左下原点）
    static func screenLineRect(editing: CGRect) -> CGRect? {
        guard editing.width > 0, editing.height > 0 else { return nil }
        let height = min(editing.height, 22)
        let top = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: editing.minX, y: top - editing.minY - height, width: 1, height: height)
    }
}
