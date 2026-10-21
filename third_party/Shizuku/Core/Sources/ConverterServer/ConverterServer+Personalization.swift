import AppKit
import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// MARK: - 場面学習（llm-ime）
//
// IME 本体がキーイベントに載せて送るメタ情報（ConverterSceneObservation）から入力の始まりで場面を決め、
// 入力中の統計（打鍵数・バックスペース・候補をどこまで見たか・「もしかして」や続き予測の表示）を集めて、
// 確定と反応を PersonalLearner に記録する。学習のスイッチがオフ（または IME 本体がメタ情報を送らない）なら何もしない。

/// セッション（入力先の欄）ごとの場面学習の状態
final class PersonalSessionState {
    /// 今の入力（なければ直前の入力）の場面
    var scene: PersonalScene?
    var observation: ConverterSceneObservation?
    /// 入力中か（入力が空になったら終わり）
    var compositionActive = false
    var compositionID: Int64 = 0
    var compositionStart: Date?
    var keys = 0
    var backspaces = 0
    var maxSelection: Int?
    var typoShown: String?
    /// 「もしかして」の訂正先の読み（ひらがな）
    var typoTarget: String?
    var typoAccepted = false
    var completionShown: String?
    var lastCommit: (id: Int64, time: Date)?
    /// Tab で確定した続き予測（次のキーで、どれだけ残っているかを見る）
    var pendingRetention: (id: Int64, text: String, time: Date)?
    /// 入力中にバックスペースで消した打鍵と、そのあと打ち直した打鍵
    var typoRemoved = ""
    var typoRetyped = ""
    /// この欄で観測した欄の形の最大（入力が進むと短い欄が長くなる。欄の形が入力の途中で変わらないようにする）
    var fieldShape: PersonalScene.Shape?
    /// 続き予測の文脈の前に置く本人の文の手本。入力を始めてから最初の予測で選び、次の入力を始めるまで変えない
    var completionPrefix: String?
    /// 入力を始めたときの左文脈の末尾（意味の近さの問いと合わせる）と、裏で作った問いのベクトル（解析と学習 段階 B）
    var inputLeft: String?
    var semanticQuery: (text: String, vector: [Float])?
    /// この欄で最後にキーを受けた時刻（何も入力していないときに手を止めた長さを数える）
    var lastKeyTime: Date?
    /// 最後の確定の後の左文脈（確定の直後に消した部分を求める）
    var lastCommitText: (text: String, time: Date)?
    /// 確定の直後に消した部分と、そのあと書いた語句とその読み（読みが分からなければ nil）。入力が終わったら言い直しとして記録する
    var pendingRewrite: (deleted: String, written: String, writtenReading: String?, time: Date)?
    /// 今「もしかして」の枠に出している言い直し（入力中の第 1 候補が、前に消した語句と同じとき）
    var rewriteOffer: (deleted: String, written: String)?
    /// 言い直しを出したために隠した続き予測と、そのあと確定した文（隠した続きと合えば「逃した続き」として記録する）
    var rewriteHiddenCompletion: (text: String, committed: String, time: Date)?
    /// 記録を消した回数（PersonalLearner.forgetGeneration）を最後に見たときの値。変わっていたら、持っている本人の文章を捨てる
    var forgetGeneration = PersonalLearner.shared.forgetGeneration
    /// 空の欄に書き始めた文字列（書き出しを集めている途中。空の欄で入力を始めたときだけ）
    var openingCapture: (scene: PersonalScene, text: String, sources: [Int64])?
    /// 空の欄で出した書き出し（次のキーが来たら使われなかった）
    var skeletonOffer: (scene: PersonalScene, text: String)?
    /// この欄に入ってから、書き出しを使われなかったと数えたか（入力欄に入るたびに 1 回まで。Cmd-Tab の往復で数を使い切らない）
    var skeletonIgnoreCounted = false
    /// 入力欄の場所（アクセシビリティを許可しているときだけ。入力欄に入るたびに裏で読み直す。読み終わるまで・読めなければ nil）
    var place: String?
    var placeGeneration = 0
    /// この欄にいる間の段とフラグだけ。名前・宛名は保持しない。
    var recipient = PersonalRecipient.State()
    var stalls = PersonalStall.Tracker()
    var sensingGeneration = -1
    var contextEpoch = -1
    var fieldContext = PersonalFieldContext()
    var closingCapture: PersonalClosing.Capture?
    var completionLeft: String?
    var restoredQuery: String?
    var contextCounted = false
    var draftChain = IdleSentenceBudget()
    var dismissedOffers: Set<String> = []

    /// 記録が消されていたら（全部・アプリごと）、このセッションが持っている本人の文章（手本・直前の確定・言い直しの途中）を捨てる
    func dropIfForgotten() {
        let generation = PersonalLearner.shared.forgetGeneration
        guard generation != self.forgetGeneration else {
            return
        }
        self.forgetGeneration = generation
        self.dismissedOffers.removeAll()
        self.completionPrefix = nil
        self.inputLeft = nil
        self.semanticQuery = nil
        self.lastCommitText = nil
        self.pendingRewrite = nil
        self.rewriteOffer = nil
        self.rewriteHiddenCompletion = nil
        self.pendingRetention = nil
        self.draftChain.reset()
        self.openingCapture = nil
        self.closingCapture = nil
        self.fieldContext.reset()
        self.completionLeft = nil
        self.restoredQuery = nil
        self.skeletonOffer = nil
        self.stalls = PersonalStall.Tracker()
    }

    func resetComposition() {
        self.compositionActive = false
        self.compositionStart = nil
        self.keys = 0
        self.backspaces = 0
        self.maxSelection = nil
        self.typoShown = nil
        self.typoTarget = nil
        self.typoAccepted = false
        self.completionShown = nil
        self.typoRemoved = ""
        self.typoRetyped = ""
    }

    /// 欄が変わった（アプリの切り替え・欄が空になった）
    func resetField() {
        self.dismissedOffers.removeAll()
        self.closingCapture = nil
        self.fieldContext.reset()
        self.completionLeft = nil
        self.restoredQuery = nil
        self.completionPrefix = nil
        self.contextCounted = false
        self.draftChain.reset()
        if let scene = self.scene, self.stalls.burstCharacters > 0 {
            PersonalLearner.shared.recordBurst(scene: scene, characters: self.stalls.burstCharacters, now: Date().timeIntervalSince1970)
        }
        self.stalls = PersonalStall.Tracker()
        self.recipient.reset()
        self.fieldShape = nil
        self.lastKeyTime = nil
        self.lastCommitText = nil
        self.pendingRewrite = nil
        self.rewriteOffer = nil
        self.rewriteHiddenCompletion = nil
    }
}

extension ConverterSession: SegmentsManagerPersonalization {
    func finishPersonalClosing() {
        personal.dropIfForgotten()
        guard personal.contextEpoch == PersonalContextMemory.shared.epoch else { personal.closingCapture = nil; return }
        guard let capture = personal.closingCapture else { return }
        personal.closingCapture = nil
        if let text = capture.closing {
            PersonalLearner.shared.recordClosing(scene: capture.scene, text: text, sources: capture.sources)
        }
    }

    func personalPreferredSurface(forReading reading: String, leftContext: String) -> PersonalLearner.Entry? {
        guard let scene = self.personal.scene else {
            return nil
        }
        return PersonalLearner.shared.preferredEntry(forReading: reading, scene: scene, leftContext: leftContext)
    }

    func personalTypoMarginAdjustment(forTarget reading: String) -> Float {
        let tuned = self.personal.scene.flatMap { scene in
            PersonalTuningScheduler.isActive ? PersonalTuner.shared.value(.typoMarginOffset, scene: scene) : nil
        } ?? 0
        return PersonalLearner.shared.typoMarginAdjustment(forTarget: reading) + Float(tuned)
    }

    func personalKanaVariantMarginAdjustment(forReading reading: String) -> Float {
        PersonalLearner.shared.kanaVariantMarginAdjustment(forReading: reading)
    }

    func segmentsManagerDidCommit(_ event: SegmentsManager.CommitEvent) {
        // 言い直しを出していたのに、別のものを確定した（使われなかった）
        if let offer = self.personal.rewriteOffer, let scene = self.personal.scene {
            self.personal.rewriteOffer = nil
            PersonalLearner.shared.recordRewriteOutcome(scene: scene, deleted: offer.deleted, written: offer.written, accepted: false)
        }
        self.recordPersonalCommit(
            kind: event.kind.rawValue,
            reading: event.reading,
            surface: event.surface,
            defaultSurface: event.defaultSurface,
            rank: event.rank,
            leftContext: event.leftContext,
            lcid: event.lcid,
            rcid: event.rcid,
            mid: event.mid,
            completionSuggestion: event.completionSuggestion
        )
        // ず/づ の置き換え: 置き換えた読みで確定した／置き換えを出したのに入力どおりの読みで確定した
        if PersonalLearner.isRecording, let typed = event.typedReading?.toKatakana(), typed.contains(where: { $0 == "ズ" || $0 == "ジ" }) {
            if PersonalLearner.isKanaVariant(typed: typed, committed: event.reading) {
                PersonalLearner.shared.recordKanaVariantOutcome(reading: typed, accepted: true, scene: self.personal.scene)
            } else if event.kanaVariantOffered, event.reading == typed {
                PersonalLearner.shared.recordKanaVariantOutcome(reading: typed, accepted: false, scene: self.personal.scene)
            }
        }
        switch event.kind {
        case .enter, .kana, .completion:
            // 入力全体を確定した（同じキーで次の入力を始めることがあるので、統計はここで区切る）
            self.finishPersonalRewrite()
            self.personal.resetComposition()
            self.personal.compositionID = 0
        case .selection, .transform:
            // 文節ごとの確定では入力が続く（入力が空になったら finishPersonalization で区切る）
            break
        }
    }

    /// 確定の直後に消してから書いた語句があれば、言い直しとして記録する（入力が終わったときに呼ぶ）
    func finishPersonalRewrite() {
        guard let pending = self.personal.pendingRewrite, !pending.written.isEmpty else {
            return
        }
        self.personal.pendingRewrite = nil
        if let scene = self.personal.scene {
            PersonalLearner.shared.recordRewrite(
                scene: scene, deleted: pending.deleted, written: pending.written, writtenReading: pending.writtenReading,
                commitID: self.personal.lastCommit?.id
            )
        }
    }

    /// 確定を記録する。続き予測の確定は、自動辞書は土台の候補だけで数え、記録には「土台＋続き」を残す
    func recordPersonalCommit(
        kind: String,
        reading: String?,
        surface: String,
        defaultSurface: String?,
        rank: Int?,
        leftContext: String,
        lcid: Int? = nil,
        rcid: Int? = nil,
        mid: Int? = nil,
        completionSuggestion: String? = nil
    ) {
        let state = self.personal
        guard PersonalLearner.isRecording, let scene = state.scene else {
            return
        }
        state.stalls.didCommit = true
        let now = Date()
        let learner = PersonalLearner.shared
        if state.compositionID == 0 {
            state.compositionID = learner.makeCompositionID()
        }
        var record = PersonalLearner.CommitRecord(
            scene: scene,
            fromApp: state.observation?.previousBundleID,
            monospaced: state.observation?.monospaced,
            kind: kind,
            reading: reading,
            surface: surface,
            defaultSurface: defaultSurface,
            rank: rank,
            depth: state.maxSelection,
            leftContext: leftContext,
            composeMilliseconds: state.compositionStart.map { Int(now.timeIntervalSince($0) * 1000) },
            keys: state.keys,
            backspaces: state.backspaces,
            composition: state.compositionID,
            lcid: lcid,
            rcid: rcid,
            mid: mid
        )
        let commitID: Int64?
        if let suggestion = completionSuggestion {
            learner.updateLexicon(with: record, ts: now.timeIntervalSince1970)
            record.surface = surface + suggestion
            record.defaultSurface = nil
            commitID = learner.recordCommit(record, now: now, updatingLexicon: false)
        } else {
            commitID = learner.recordCommit(record, now: now)
        }
        guard let commitID else {
            return
        }
        let authored = PersonalOrigin.normalKinds.contains(kind) && completionSuggestion == nil
        if state.closingCapture == nil { state.closingCapture = .init(scene: scene) }
        state.closingCapture?.scene = scene
        state.closingCapture?.append(record.surface, source: commitID, authored: authored)
        state.fieldContext.append(record.surface, authored: authored)
        PersonalContextMemory.shared.carry.append(record.surface, app: scene.app, authored: authored)
        state.stalls.lastDeleted = 0
        if PersonalOrigin.normalKinds.contains(kind) { state.stalls.burstCharacters += surface.count }
        learner.linkStalls(state.stalls.linkable(now: now.timeIntervalSince1970), commitID: commitID, now: now.timeIntervalSince1970)
        state.lastCommit = (commitID, now)
        state.lastCommitText = (leftContext + record.surface, now)
        // 次の入力の手本選びに使う問いのベクトルを裏で作っておく（意味の近さを使うときだけ。確定は主スレッドで届く）
        if Thread.isMainThread {
            nonisolated(unsafe) let session = self
            let left = leftContext + record.surface
            MainActor.assumeIsolated {
                PersonalEmbeddingService.shared.prepareQuery(leftContext: left, for: session)
            }
        }
        if var pending = state.pendingRewrite {
            pending.written += record.surface
            // 続き予測で入れた部分の読みは分からない
            pending.writtenReading = completionSuggestion == nil ? pending.writtenReading.flatMap { known in reading.map { known + $0 } } : nil
            state.pendingRewrite = pending
        }
        // 空の欄の書き出し: 最初の文が終わったら記録する
        if let capture = state.openingCapture {
            let next = PersonalOpening.append(capture.text, record.surface)
            state.openingCapture = next.capture.map { (capture.scene, $0, capture.sources + [commitID]) }
            if let opening = next.opening {
                learner.recordOpening(scene: capture.scene, text: opening, sources: capture.sources + [commitID], now: now)
            }
        }
        // 言い直しで隠した続き予測を、そのあと自分で書いた（逃した続き）
        if let hidden = state.rewriteHiddenCompletion {
            let committed = hidden.committed + record.surface
            if now.timeIntervalSince(hidden.time) > 120 || !(committed.hasPrefix(hidden.text) || hidden.text.hasPrefix(committed)) {
                state.rewriteHiddenCompletion = nil
            } else if committed.count >= hidden.text.count {
                learner.recordReaction(kind: "rewrite_missed_completion", scene: scene, commitID: commitID, a: hidden.text, now: now)
                state.rewriteHiddenCompletion = nil
            } else {
                state.rewriteHiddenCompletion = (hidden.text, committed, hidden.time)
            }
        }
        // 反応: 続き予測・「もしかして」を出したのに使わなかった／使った
        if let suggestion = completionSuggestion {
            learner.recordReaction(kind: "completion_accepted", scene: scene, commitID: commitID, a: suggestion, n: suggestion.count, now: now)
            WindowEffectRecorder.note(kind: "completion", used: self.completionUsedReference, accepted: true, scene: scene)
            state.pendingRetention = (commitID, surface + suggestion, now)
        } else if let shown = state.completionShown {
            learner.recordReaction(kind: "completion_ignored", scene: scene, commitID: commitID, a: shown, now: now)
        }
        if let shown = state.typoShown, !state.typoAccepted {
            learner.recordReaction(kind: "typo_ignored", scene: scene, commitID: commitID, a: shown, b: state.typoTarget, now: now)
            if let target = state.typoTarget {
                learner.recordTypoOutcome(target: target.toKatakana(), accepted: false)
            }
        }
        state.completionShown = nil
        state.typoShown = nil
        state.typoTarget = nil
        state.typoAccepted = false
    }
}

extension ConverterServer {
    /// キーイベントを処理する前に呼ぶ。学習が有効なら、入力の始まりで場面を決め、前の確定への反応（確定直後のバックスペース、
    /// Tab で入れた続き予測がどれだけ残ったか）を記録する。学習を使うかどうか（SegmentsManager に差し込むか）を返す
    @MainActor
    func preparePersonalization(session: ConverterSession, request: ConverterKeyEventRequest) {
        let contextMemory = PersonalContextMemory.shared
        contextMemory.observe(app: request.scene?.bundleID, enabled: PersonalLearner.isRecording, now: Date().timeIntervalSince1970, previousApp: request.scene?.previousBundleID)
        guard PersonalLearner.isEnabled, let observation = request.scene else {
            session.personal.closingCapture = nil
            session.personal.fieldContext.reset()
            session.personal.completionLeft = nil
            session.personal.restoredQuery = nil
            session.manager.personalization = nil
            session.personal.scene = nil
            session.personal.recipient.reset()
            return
        }
        session.manager.personalization = session
        let state = session.personal
        state.dropIfForgotten()
        if state.contextEpoch != contextMemory.epoch {
            state.closingCapture = nil
            state.fieldContext.reset(); state.completionLeft = nil; state.restoredQuery = nil; state.completionPrefix = nil
            if state.fieldShape == .code || state.fieldShape == .md { state.fieldShape = nil }
            state.contextEpoch = contextMemory.epoch
        }
        let previousApp = state.observation?.bundleID
        state.observation = observation
        if observation.backspacesAfterCommit > 0 {
            if let app = observation.bundleID { contextMemory.carry.discardOwn(app: app) }
            state.closingCapture = nil; state.fieldContext.reset(); state.completionLeft = nil; state.restoredQuery = nil; state.completionPrefix = nil
        }
        let contextAllowed = PersonalLearner.isRecording && observation.bundleID.map { !PersonalPrivacy.isExcluded(app: $0) } ?? false
        if !contextAllowed { state.closingCapture = nil; state.fieldContext.reset(); state.completionLeft = nil; state.restoredQuery = nil }
        // 空の欄で出した書き出しを使わずに、キーを押した（入力欄に入るたびに 1 回まで）。欄を出入りした後の最初のキーは、
        // 書き出しが消えた後なので数えない
        if request.activation != nil {
            state.skeletonOffer = nil
            state.skeletonIgnoreCounted = false
        } else if let offer = state.skeletonOffer {
            state.skeletonOffer = nil
            if !state.skeletonIgnoreCounted {
                state.skeletonIgnoreCounted = true
                PersonalLearner.shared.recordOpeningOutcome(scene: offer.scene, text: offer.text, accepted: false)
            }
        }
        // 書き出しを集めている途中で欄が変わった・空になった（文末なしで送った）: そこまでを書き出しとする。
        // 空になったかは、入力の始まりで、欄の長さが 0 で左文脈も空と分かるときだけ（入力中のキーや、長さをいつも 0 と返すアプリで
        // 途中で切らない）
        let switchedField = request.activation != nil || previousApp != observation.bundleID
        let sentField = !switchedField && session.manager.isEmpty && observation.documentLength == 0 && request.context.leftSideContext == ""
        if switchedField || sentField { session.finishPersonalClosing() }
        if sentField && !state.fieldContext.buffer.isEmpty {
            state.fieldContext.finish(now: Date().timeIntervalSince1970, sent: true)
        }
        if let capture = state.openingCapture, switchedField || sentField {
            state.openingCapture = nil
            if let text = PersonalOpening.extract(capture.text, final: true) {
                PersonalLearner.shared.recordOpening(scene: capture.scene, text: text, sources: capture.sources)
            }
        }
        if request.activation != nil || previousApp != observation.bundleID {
            let entry = (state.stalls.entered, state.stalls.entryKnown && state.stalls.firstKey)
            state.resetField()
            if (request.activation != nil || previousApp == nil), entry.1 { state.stalls.entered = entry.0; state.stalls.entryKnown = true }
            // 入力欄の場所を読み直す（許可・設定・学習がなければ問い合わせない。キー入力の処理は待たない）
            state.place = nil
            state.placeGeneration += 1
            if let app = observation.bundleID {
                let generation = state.placeGeneration
                PersonalAccessibility.readPlace(app: app) { [weak state] place in
                    guard let state, state.placeGeneration == generation else {
                        return
                    }
                    state.place = place
                }
            }
        } else if observation.documentLength == 0, request.context.leftSideContext == "" {
            // 欄が空になった（送信した）: 欄の形だけ測り直す。手を止めた長さ・直前の確定は保つ。
            // 欄の長さをいつも 0 と返すアプリがあるので、左文脈も空と分かるときだけ
            state.fieldShape = nil
            state.recipient.reset()
        }
        var observedScene = PersonalScene.classify(
            observation: observation,
            leftContext: request.context.leftSideContext,
            rightContext: request.context.rightSideContext
        )
        if let mode = observedScene?.mode {
            state.recipient.observe(mode: mode, left: request.context.leftSideContext, enabled: true,
                startedEmpty: observation.startedEmpty || (observation.documentLength == 0 && request.context.leftSideContext == ""))
        }
        if contextAllowed, let shape = PersonalMarkup.shape(left: request.context.leftSideContext ?? "", right: request.context.rightSideContext ?? "", monospaced: observation.monospaced == true) {
            observedScene?.shape = shape
            // code/mdの引用記号は返信の証拠にしない。
            observedScene?.reply = false
        }
        observedScene?.recipient = state.recipient.rank
        state.scene?.recipient = state.recipient.rank
        if session.manager.isEmpty, var scene = observedScene {
            // 欄の形は、この欄で観測した最大のものにする（書き進めて長くなっても、同じ欄の場面を保つ）
            let order = PersonalScene.Shape.allCases
            if let shape = state.fieldShape, order.firstIndex(of: shape)! > order.firstIndex(of: scene.shape)! {
                scene.shape = shape
            }
            if contextAllowed && state.fieldShape != scene.shape {
                if scene.shape == .code { contextMemory.code += 1 }
                if scene.shape == .md { contextMemory.markdown += 1 }
            }
            if scene.shape == .code || scene.shape == .md { scene.reply = false }
            state.fieldShape = scene.shape
            scene.place = state.place
            state.scene = scene
            state.completionPrefix = nil
            state.contextCounted = false
            if contextAllowed {
                let original = request.context.leftSideContext
                state.closingCapture?.observe(left: original)
                let restored = state.fieldContext.restoredLeft(original)
                state.restoredQuery = restored != original ? restored : nil
                state.completionLeft = restored
            }
            // 意味の近さの問い: 入力を始めたときの左文脈。確定の後に作っておいたものと違えば、次のために裏で作る
            state.inputLeft = request.context.leftSideContext.map { String($0.suffix(PersonalEmbeddingService.queryLength)) }
            if let left = request.context.leftSideContext {
                PersonalEmbeddingService.shared.prepareQuery(leftContext: left, for: session)
            }
        }
        guard PersonalLearner.isRecording, let scene = state.scene else {
            return
        }
        let now = Date()
        // 空の欄で書き始めた（左文脈が空と分かっていて、欄の長さも 0）: 書き出しを集め始める。左文脈が分からないアプリ（nil）では集めない
        if session.manager.isEmpty, state.openingCapture == nil, request.context.leftSideContext == "", observation.documentLength == 0,
           !(request.context.rightSideContext ?? "").contains(where: { !$0.isWhitespace }) {
            state.openingCapture = (scene, "", [])
        }
        // 何も入力していないときに手を止めた長さ（同じ欄の前のキーから）。迷いの検知で使う
        if request.activation == nil, session.manager.isEmpty, let last = state.lastKeyTime {
            PersonalLearner.shared.recordPause(scene: scene, seconds: now.timeIntervalSince(last), now: now)
        }
        state.lastKeyTime = now
        // 前の確定の直後にアプリで押したバックスペース（確定の取り消し・外れ）
        if observation.backspacesAfterCommit > 0, let last = state.lastCommit, now.timeIntervalSince(last.time) < 120 {
            PersonalLearner.shared.recordReaction(
                kind: "bs_after_commit", scene: scene, commitID: last.id, n: observation.backspacesAfterCommit, now: now
            )
        }
        // 確定の直後に消した部分（このあと書く語句と対にして、言い直しとして記録する）
        if session.manager.isEmpty {
            if observation.backspacesAfterCommit > 0, let last = state.lastCommitText, now.timeIntervalSince(last.time) < 120,
               let deleted = PersonalRewrite.deletedSpan(
                afterCommit: last.text, backspaces: observation.backspacesAfterCommit, leftContextNow: request.context.leftSideContext
               ) {
                state.pendingRewrite = (deleted, "", "", now)
                state.lastCommitText = nil
            } else if let pending = state.pendingRewrite, now.timeIntervalSince(pending.time) > 60 {
                state.pendingRewrite = nil
            }
        }
        // Tab で入れた続き予測のうち、次に入力を始めたときに残っていた長さ（書き換えられた量）
        if let retention = state.pendingRetention, session.manager.isEmpty {
            state.pendingRetention = nil
            if now.timeIntervalSince(retention.time) < 300 {
                let left = request.context.leftSideContext ?? ""
                let kept = Self.keptPrefixLength(of: retention.text, in: left)
                PersonalLearner.shared.recordReaction(
                    kind: "completion_kept", scene: scene, commitID: retention.id, b: String(retention.text.count), n: kept, now: now
                )
            }
        }
    }

    /// 入れた文字列のうち、左文脈の末尾に残っている先頭部分の長さ
    static func keptPrefixLength(of inserted: String, in left: String) -> Int {
        let tail = String(left.suffix(inserted.count + 40))
        if tail.contains(inserted) {
            return inserted.count
        }
        let characters = Array(inserted)
        for length in stride(from: characters.count - 1, through: 1, by: -1) where tail.hasSuffix(String(characters[0..<length])) {
            return length
        }
        return 0
    }

    /// キーイベントの処理の後に呼ぶ。入力中の統計（打鍵・バックスペース・候補の掘り下げ・「もしかして」）と打ち直しの対を集める
    @MainActor
    func finishPersonalization(
        session: ConverterSession,
        action: ClientAction,
        rawInputBefore: String,
        typoSuggestionBefore: String?
    ) {
        guard session.manager.personalization != nil else {
            return
        }
        let state = session.personal
        let manager = session.manager
        guard !manager.isEmpty else {
            // 入力が終わった（確定・取り消し）
            // 確定せずに消した入力（打ちかけてやめた）。続き予測を出していれば使われなかった（確定していれば記録の時に消している）
            if state.compositionActive, PersonalLearner.isRecording, let shown = state.completionShown {
                PersonalLearner.shared.recordReaction(kind: "completion_ignored", scene: state.scene, a: shown)
            }
            session.finishPersonalRewrite()
            state.resetComposition()
            state.compositionID = 0
            return
        }
        if !state.compositionActive {
            state.compositionActive = true
            state.compositionStart = Date()
            state.compositionID = PersonalLearner.shared.makeCompositionID()
        }
        state.keys += 1
        if let index = manager.currentSelectionIndex {
            state.maxSelection = max(state.maxSelection ?? 0, index)
        }
        // 「もしかして」を出した・使った
        if case .acceptPredictionCandidate = action, let shown = typoSuggestionBefore {
            state.typoAccepted = true
            if PersonalLearner.isRecording {
                // 受け入れた後の読みが訂正先
                PersonalLearner.shared.recordReaction(kind: "typo_accepted", scene: state.scene, a: shown, b: manager.convertTarget)
                PersonalLearner.shared.recordTypoOutcome(target: manager.convertTarget.toKatakana(), accepted: true)
            }
        }
        // 打ち直し: バックスペースで消した打鍵と、そのあと打ち直した打鍵の対
        guard manager.isRomanInput else {
            state.typoRemoved = ""
            state.typoRetyped = ""
            return
        }
        let rawAfter = manager.rawInputString
        switch action {
        case .removeLastMarkedText:
            state.backspaces += 1
            if rawInputBefore.hasPrefix(rawAfter) {
                let removed = String(rawInputBefore.dropFirst(rawAfter.count))
                // 続けて消した分は前に足す（打ち直しを始める前だけ）
                state.typoRemoved = state.typoRetyped.isEmpty ? removed + state.typoRemoved : removed
                state.typoRetyped = ""
            } else {
                state.typoRemoved = ""
                state.typoRetyped = ""
            }
        case .appendToMarkedText, .appendPieceToMarkedText:
            guard !state.typoRemoved.isEmpty, rawAfter.hasPrefix(rawInputBefore) else {
                return
            }
            state.typoRetyped += rawAfter.dropFirst(rawInputBefore.count)
            if state.typoRetyped.count >= state.typoRemoved.count {
                let fixed = String(state.typoRetyped.prefix(state.typoRemoved.count))
                if PersonalLearner.isRecording {
                    PersonalLearner.shared.recordTypoPair(
                        typed: state.typoRemoved, fixed: fixed, reading: manager.convertTarget, scene: state.scene
                    )
                }
                state.typoRemoved = ""
                state.typoRetyped = ""
            }
        default:
            state.typoRemoved = ""
            state.typoRetyped = ""
        }
    }

    /// 続き予測の文脈の前に置く本人の文の手本（学習がオフ・記録が少なければ空）
    @MainActor
    func synchronizePersonalContext(session: ConverterSession) {
        let memory = PersonalContextMemory.shared, state = session.personal
        memory.refresh()
        state.dropIfForgotten()
        if state.contextEpoch != memory.epoch || !PersonalLearner.isEnabled
            || state.scene.map({ PersonalPrivacy.isExcluded(app: $0.app) }) != false {
            state.fieldContext.reset(); state.closingCapture = nil
            state.completionLeft = nil; state.restoredQuery = nil; state.completionPrefix = nil
            state.contextEpoch = memory.epoch
        } else if !PersonalLearner.isRecording {
            state.fieldContext.reset(); state.closingCapture = nil
            state.completionLeft = nil; state.restoredQuery = nil
        }
    }

    /// キーを伴わないE4B（下書き・放置）にも同じ照合と期限を使う。
    @MainActor
    func personalContinuationContext(session: ConverterSession, left: String) -> String {
        self.synchronizePersonalContext(session: session)
        guard PersonalLearner.isRecording, let scene = session.personal.scene, !PersonalPrivacy.isExcluded(app: scene.app) else { return left }
        let state = session.personal
        state.closingCapture?.observe(left: left)
        let restored = state.fieldContext.restoredLeft(left) ?? left
        state.restoredQuery = restored == left ? nil : restored
        if restored != left { PersonalContextMemory.shared.restored += 1 }
        let result = state.fieldContext.completionLeft(restored, now: Date().timeIntervalSince1970)
        if result != restored { PersonalContextMemory.shared.sent += 1 }
        return result
    }

    @MainActor
    func personalCompletionRequest(session: ConverterSession, request: SegmentsManager.NextTextCompletionRequest?) -> SegmentsManager.NextTextCompletionRequest? {
        self.synchronizePersonalContext(session: session)
        guard var request, PersonalLearner.isRecording, let scene = session.personal.scene,
              !PersonalPrivacy.isExcluded(app: scene.app), let left = session.personal.completionLeft else { return request }
        let state = session.personal
        let completedLeft = state.fieldContext.completionLeft(left, now: Date().timeIntervalSince1970)
        if !state.contextCounted {
            if state.restoredQuery != nil { PersonalContextMemory.shared.restored += 1 }
            if completedLeft != left { PersonalContextMemory.shared.sent += 1 }
            state.contextCounted = true
        }
        request.context = completedLeft + request.base
        return request
    }

    @MainActor
    func personalCompletionPrefix(session: ConverterSession, context: String) -> String {
        self.synchronizePersonalContext(session: session)
        guard PersonalLearner.isEnabled, session.manager.personalization != nil, let scene = session.personal.scene,
              !PersonalPrivacy.isExcluded(app: scene.app) else { return "" }
        let cached = session.personal.completionPrefix
        let prefix = cached ?? PersonalLearner.shared.completionPrefix(
            scene: scene, context: context,
            queryVector: session.personal.restoredQuery == nil ? PersonalEmbeddingService.shared.queryVector(for: session) : nil,
            query: session.personal.restoredQuery == nil ? nil : context
        )
        // 手本の検索だけをキャッシュし、持ち越す本文と期限は毎回確認する。
        session.personal.completionPrefix = prefix
        let carried = PersonalLearner.isRecording
            ? PersonalContextMemory.shared.carry.prefix(now: Date().timeIntervalSince1970, app: scene.app) : ""
        if cached == nil && !carried.isEmpty { PersonalContextMemory.shared.appCarried += 1 }
        return carried + prefix
    }

    /// いい感じ変換（ローカル LLM）に渡す、この場面で本人が前に書いた似た文（学習がオフ・記録が少なければ空）。
    /// 入力中の読みの第 1 候補と左文脈の末尾で探す
    @MainActor
    func personalMagicConversionExamples(session: ConverterSession, leftContext: String) throws -> [String] {
        guard session.manager.personalization != nil, let scene = session.personal.scene else {
            return []
        }
        let converted = try self.kanaKanjiConverter.withSession(session.conversionSessionID) {
            session.manager.refineFirstCandidate()?.text
        } ?? session.manager.convertTarget
        let query = String(leftContext.suffix(20)) + converted
        return PersonalLearner.shared.corpus.styleExamples(query: query, scene: scene, excluding: leftContext,
            queryVector: PersonalEmbeddingService.shared.queryVector(for: session))
    }

    /// 放置で続きを出すまでの待ち時間（本体に返す値。nil なら本体の既定 3 秒）。自己調整がオンなら、本人のリズム（迷いの検知）か
    /// 調整した秒数。学習・自己調整がオフ、場面がなければ nil
    @MainActor
    func personalIdleDelay(session: ConverterSession) -> Double? {
        guard session.manager.personalization != nil, PersonalTuningScheduler.isActive, let scene = session.personal.scene else {
            return nil
        }
        return PersonalTuner.shared.idleDelay(scene: scene, pauses: PersonalLearner.shared.pauseHistograms)
    }

    /// 自己調整した値（場面学習・自己調整がオフ、場面がない、調整していなければ nil＝既定）
    @MainActor
    func personalTunedValue(_ knob: PersonalTuner.Knob, session: ConverterSession) -> Double? {
        guard session.manager.personalization != nil, PersonalTuningScheduler.isActive, let scene = session.personal.scene else {
            return nil
        }
        return PersonalTuner.shared.value(knob, scene: scene)
    }

    /// 言い直しを「もしかして」の枠に出すか（出すなら書き直した語句）。入力中の第 1 候補 firstCandidate が、この場面で 3 回（自己調整で
    /// 2 回まで下がる）同じように消して書き直した語句のときだけ。出したもの・隠した続き予測を覚え、出したのが変わったら記録する
    @MainActor
    func personalRewriteOffer(session: ConverterSession, firstCandidate: String?, present: Bool = true) -> String? {
        let state = session.personal
        guard session.manager.personalization != nil, let scene = state.scene, let first = firstCandidate,
              let written = PersonalLearner.shared.rewriteSuggestion(
                scene: scene, firstCandidate: first, reading: session.manager.convertTarget,
                repeats: PersonalTuningScheduler.isActive ? PersonalTuner.shared.rewriteRepeats(scene: scene) : PersonalRewrite.defaultRepeats
              ) else {
            if present { state.rewriteOffer = nil }
            return nil
        }
        guard present else { return written }
        if state.rewriteOffer?.deleted != first || state.rewriteOffer?.written != written {
            state.rewriteOffer = (first, written)
            let hidden = session.manager.nextTextCompletionFullText
            if let hidden {
                state.rewriteHiddenCompletion = (hidden, "", Date())
            }
        }
        return written
    }

    /// 出している言い直しを Tab で入れる（入れた語句を返す。出していなければ nil）。第 1 候補の変換は使わず、書き直した語句をそのまま確定する
    @MainActor
    func acceptPersonalRewrite(session: ConverterSession, leftSideContext: String) -> String? {
        let state = session.personal
        guard session.manager.personalization != nil, let offer = state.rewriteOffer, let scene = state.scene else {
            return nil
        }
        state.rewriteOffer = nil
        state.rewriteHiddenCompletion = nil
        let reading = PersonalLearner.shared.rewriteReading(scene: scene, deleted: offer.deleted, written: offer.written)
        session.recordPersonalCommit(
            kind: "rewrite", reading: reading, surface: offer.written, defaultSurface: offer.written, rank: nil, leftContext: leftSideContext
        )
        PersonalLearner.shared.recordRewriteOutcome(scene: scene, deleted: offer.deleted, written: offer.written, accepted: true)
        session.manager.stopComposition()
        return offer.written
    }

    /// 続き予測を出した（入力中の予測が表示できる状態になった）
    @MainActor
    func notePersonalCompletionShown(session: ConverterSession, text: String) {
        // 言い直しを出している間は、続き予測は見えていない
        guard session.manager.personalization != nil else {
            return
        }
        session.personal.completionShown = text
    }

    /// 空の欄で出す、その場面のいつもの書き出し（骨組み）。学習・続き予測・放置の続きがオフ、場面が分からない、記録が足りなければ nil
    @MainActor
    func personalSkeleton(session: ConverterSession, observation: ConverterSceneObservation) async -> String? {
        guard PersonalLearner.isEnabled, Config.NextTextCompletion().value, Config.NextTextCompletionIdle().value, session.manager.isEmpty,
              observation.documentLength == 0,
              var scene = PersonalScene.classify(observation: observation, leftContext: "", rightContext: nil) else {
            return nil
        }
        guard !PersonalSensing.shared.muteGeneration(kind: "skeleton", scene: scene),
              automaticOfferAllowed(.skeleton, session: session, scene: scene), session.offers.mayPrepare(.skeleton) else { return nil }
        // まだキーを押していない欄なので、場所はここで読む（許可・設定・学習がなければ問い合わせない）
        scene.place = await PersonalAccessibility.place(app: scene.app)
        guard session.manager.isEmpty, !PersonalSensing.shared.microphoneActive, let text = PersonalLearner.shared.openingSuggestion(scene: scene) else {
            return nil
        }
        let shown = emptyOffer(.skeleton, text: text, session: session, scene: scene)
        if session.offers.current?.kind == .skeleton, let shown { session.personal.skeletonOffer = (scene, shown) }
        return shown
    }

    /// 何も入力していない状態の続き予測を出した・Tab で入れた
    @MainActor
    func notePersonalIdleCompletion(session: ConverterSession, shown: String? = nil, accepted: String? = nil) {
        if accepted != nil {
            session.beginOfferStop()
            session.personal.draftChain.reset()
            session.personal.closingCapture = nil
            session.personal.fieldContext.reset()
            session.personal.completionLeft = nil; session.personal.restoredQuery = nil
        }
        // 空の欄で出した書き出しを Tab で入れた（放置の続きの採用率には数えない）
        if let accepted, let offer = session.personal.skeletonOffer, !accepted.isEmpty, offer.text.hasPrefix(accepted) {
            session.personal.skeletonOffer = nil
            guard PersonalLearner.isRecording else {
                return
            }
            let commitID = PersonalLearner.shared.recordCommit(.init(
                scene: offer.scene,
                fromApp: session.personal.observation?.previousBundleID,
                kind: "skeleton",
                reading: nil,
                surface: accepted,
                defaultSurface: nil
            ))
            PersonalLearner.shared.recordOpeningOutcome(scene: offer.scene, text: accepted, accepted: true)
            if let commitID { PersonalLearner.shared.recordOpening(scene: offer.scene, text: accepted, sources: [commitID]) }
            if let commitID {
                session.personal.lastCommit = (commitID, Date())
            }
            session.personal.lastCommitText = (accepted, Date())
            return
        }
        guard session.manager.personalization != nil, PersonalLearner.isRecording, let scene = session.personal.scene else {
            return
        }
        if let shown {
            // そのときの待ち時間（本体に返した値。なければ既定）も残す（迷いの検知の前後で比べる）
            let delay = self.personalIdleDelay(session: session) ?? PersonalRhythm.fixedIdleDelay
            PersonalLearner.shared.recordReaction(kind: "idle_shown", scene: scene, a: shown, b: String(format: "%.2f", delay))
            WindowEffectRecorder.note(kind: "idle", used: session.idleUsedReference, accepted: false, scene: scene)
        }
        if let accepted {
            let commitID = PersonalLearner.shared.recordCommit(.init(
                scene: scene,
                fromApp: session.personal.observation?.previousBundleID,
                kind: "idle",
                reading: nil,
                surface: accepted,
                defaultSurface: nil
            ))
            PersonalLearner.shared.recordReaction(kind: "idle_accepted", scene: scene, commitID: commitID, a: accepted, n: accepted.count)
            WindowEffectRecorder.note(kind: "idle", used: session.idleUsedReference, accepted: true, scene: scene)
            if let commitID {
                session.personal.lastCommit = (commitID, Date())
                session.personal.pendingRetention = (commitID, accepted, Date())
            }
            session.personal.lastCommitText = (accepted, Date())
            if var pending = session.personal.pendingRewrite {
                pending.written += accepted
                pending.writtenReading = nil
                session.personal.pendingRewrite = pending
                session.finishPersonalRewrite()
            }
        }
    }
}

// MARK: - 設定画面の「Shizuku が覚えたこと」（llm-ime）
//
// IME 本体（サンドボックス）は記録を読めないので、モデルの選択肢と同じく設定の項目として返す。
// 覚えた語・アプリはスイッチ（オフにすると忘れる・記録しない）、全削除と書き出しは特別なキーで受ける

extension ConverterServer {
    @MainActor
    static func personalLearningDescriptors(capabilities: ConverterSettingClientCapabilities) -> [ConverterSettingDescriptor] {
        let section = "場面学習"
        let learner = PersonalLearner.shared
        var descriptors: [ConverterSettingDescriptor] = [
            .init(
                key: Config.PersonalLearning.key,
                title: "使うほど本人に合わせる（場面学習）",
                section: section,
                kind: .toggle,
                value: .bool(Config.PersonalLearning().value)
            ),
            .init(
                key: Config.PersonalLearningPaused.key,
                title: "記録を一時停止する",
                section: section,
                kind: .toggle,
                value: .bool(Config.PersonalLearningPaused().value)
            ),
            .init(
                key: Config.PersonalLearningRetentionDays.key,
                title: "記録を残す期間",
                section: section,
                kind: .selector(options: [
                    .init(title: "30 日", value: .int(30)),
                    .init(title: "90 日", value: .int(90)),
                    .init(title: "180 日", value: .int(180)),
                    .init(title: "1 年", value: .int(365)),
                    .init(title: "期限なし", value: .int(0))
                ]),
                value: .int(Config.PersonalLearningRetentionDays().value)
            )
        ]
        let reactions = learner.reactionCounts()
        let accepted = reactions["completion_accepted", default: 0]
        let ignored = reactions["completion_ignored", default: 0]
        var summary = "記録した確定 \(learner.commitCount) 件・覚えた語 \(learner.learnedWords().count) 件・文脈で選んだ表記 \(learner.contextChoiceCount) 件"
            + "・打ち直し \(reactions["typo_pairs", default: 0]) 件"
        if accepted + ignored > 0 {
            summary += "・続き予測の採用 \(accepted)/\(accepted + ignored)"
        }
        // 数だけ（文章は出さない）
        summary += "・手を止めた記録 \(learner.pauseHistograms["global"]?.total ?? 0) 回・言い直し \(learner.rewriteCount) 件"
        let privacy = learner.rewritePrivacySummary()
        if !privacy.isEmpty { summary += "\n" + privacy }
        summary += "\n" + PersonalContextMemory.shared.summary
        summary += "\n" + ConverterResourceStatus.summary
        summary += "\n" + learner.resourceUsageSummary()
        summary += "\nマイク区間: " + (PersonalSensing.shared.microphoneActive ? "1" : "0")
        summary += "\n" + learner.microphoneMuteSummary()
        summary += "\n" + learner.offerTrustSummary()
        summary += "\n" + learner.windowEffectSummary()
        let stalls = learner.stallSummary()
        if !stalls.isEmpty { summary += "\n" + stalls }
        let closings = learner.closingSummary()
        if !closings.isEmpty { summary += "\n" + closings }
        summary += "\n" + learner.teachingSummary() + "\n" + learner.tabOwnerSummary()
        let origin = learner.originSummary()
        if !origin.isEmpty { summary += "\n" + origin }
        descriptors.append(.init(
            key: Config.personalLearningSummaryKey, title: summary, section: section, kind: .textField(secure: false),
            value: .string(summary), isEnabled: false
        ))
        descriptors.append(.init(
            key: Config.PersonalAccessibilityPlaces.key,
            title: "アクセシビリティで場面を細かく見分ける",
            section: section + ":アクセシビリティ",
            kind: .toggle,
            value: .bool(Config.PersonalAccessibilityPlaces().value)
        ))
        descriptors.append(.init(
            key: Config.personalLearningAccessibilityStatusKey,
            title: PersonalAccessibility.isTrusted
                ? (Config.PersonalAccessibilityPlaces().value ? "許可されています（使っています）" : "許可されています（使っていません）")
                : "許可されていません（今のまま、場所は見分けません）",
            section: section + ":アクセシビリティ",
            kind: .textField(secure: false),
            value: .string(""),
            isEnabled: false
        ))
        descriptors.append(.init(
            key: Config.PersonalLearningSelfTuning.key,
            title: "使い方に合わせて自動で調整する",
            section: section,
            kind: .toggle,
            value: .bool(Config.PersonalLearningSelfTuning().value)
        ))
        // 自己調整した値（場面ごと）。設定画面に一覧で出す
        let tuned = PersonalTuner.shared.settings.flatMap { level, knobs in
            knobs.map { knob, setting -> String in
                let place: String
                if level == "global" {
                    place = "全体"
                } else if level.hasPrefix("app:") {
                    place = Self.appDisplayName(String(level.dropFirst(4)))
                } else {
                    place = PersonalScene(key: level).map { Self.appDisplayName($0.app) + "・" + $0.shapeAndModeLabel } ?? level
                }
                let name = switch knob {
                case .completionThreshold: "続き予測の自信のしきい値"
                case .idleDelay: "放置から続きを出すまで"
                case .typoMarginOffset: "「もしかして」のしきい値の調整"
                case .idleRhythm: "放置から続きを出すまでを本人のリズムに"
                case .idleQuantile: "いつもより長く止まったとみなす割合"
                case .rewriteRepeats: "言い直しを出すまでの回数"
                }
                let value: String = switch knob {
                case .idleDelay: String(format: "%.1f 秒", setting.value)
                case .idleRhythm:
                    setting.value >= 1
                        ? PersonalRhythm.personalDelay(
                            histograms: [learner.pauseHistograms[level]], quantile: PersonalTuner.shared.settings[level]?[.idleQuantile]?.value ?? PersonalRhythm.defaultQuantile
                        ).map { String(format: "（今は %.1f 秒）", $0) } ?? "" : "しない"
                case .idleQuantile: String(format: "%.0f%%", setting.value * 100)
                case .rewriteRepeats: String(format: "%.0f 回", setting.value)
                default: String(format: "%+.2f", setting.value)
                }
                return "\(place): \(name) \(value)" + (setting.isOnTrial ? "（試行中）" : "")
            }
        }.sorted()
        descriptors.append(.init(
            key: Config.personalLearningTuningSummaryKey,
            title: tuned.isEmpty ? "調整した値はまだありません（記録がたまると場面ごとに合わせます）" : tuned.joined(separator: "\n"),
            section: section, kind: .textField(secure: false), value: .string(tuned.joined(separator: "\n")), isEnabled: false
        ))
        for word in learner.learnedWords() {
            let where_ = word.scene.map { Self.appDisplayName($0.app) + "・" + $0.shapeAndModeLabel } ?? ""
            descriptors.append(.init(
                key: Config.personalLearningWordKeyPrefix + word.id,
                title: "\(word.reading.toHiragana()) → \(word.surface)（\(where_)、\(word.count) 回）",
                section: section + ":覚えた語",
                kind: .toggle,
                value: .bool(true)
            ))
        }
        // 入力欄に合わせた入力モード: アプリごとに覚えたモード（オフにすると忘れる）
        for (app, votes) in learner.inputModeVotes.sorted(by: { $0.key < $1.key }) {
            guard let language = PersonalInputMode.preferred(votes) else {
                continue
            }
            let count = votes.counts.values.reduce(0, +)
            descriptors.append(.init(
                key: Config.personalLearningInputModeKeyPrefix + app,
                title: "\(Self.appDisplayName(app)): \(language == .english ? "英数" : "かな")（\(count) 回）",
                section: section + ":入力モード",
                kind: .toggle,
                value: .bool(true)
            ))
        }
        let excluded = PersonalPrivacy.userExcludedApps()
        var apps = learner.appsWithRecords().map { ($0.app, $0.count > 0 ? "\($0.count) 件" : "記録あり") }
        for app in excluded.sorted() where !apps.contains(where: { $0.0 == app }) {
            apps.append((app, "記録しない"))
        }
        for app in AssistanceSettings.apps.keys.sorted() where !apps.contains(where: { $0.0 == app }) {
            apps.append((app, "設定あり"))
        }
        for (app, detail) in apps where !PersonalPrivacy.defaultExcludedApps.contains(app) {
            descriptors.append(.init(
                key: Config.personalLearningAppKeyPrefix + app,
                title: "\(Self.appDisplayName(app))（\(detail)）",
                section: section + ":アプリ",
                kind: .toggle,
                value: .bool(!excluded.contains(app))
            ))
        }
        return descriptors
    }

    /// bundle ID からアプリの表示名
    static func appDisplayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// 場面学習の設定・操作。扱ったら true
    @MainActor
    static func updatePersonalLearningSetting(key: String, value: ConverterSettingValue) throws -> Bool {
        switch key {
        case Config.PersonalLearning.key:
            guard case .bool(let enabled) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            if !enabled {
                PersonalLearner.shared.flush()
                PersonalContextMemory.shared.reset()
            }
            Config.PersonalLearning().value = enabled
            PersonalSensing.shared.configure(scene: nil)
            if !enabled { LabController.shared.learningDisabled() }
        case Config.PersonalInputModeSwitching.key:
            guard case .bool(let enabled) = value else { throw ConverterServerError.invalidSettingValue(key) }
            Config.PersonalInputModeSwitching().value = enabled
        case Config.PersonalLearningPaused.key:
            guard case .bool(let paused) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            if paused {
                PersonalLearner.shared.flush()
                PersonalContextMemory.shared.reset()
            }
            Config.PersonalLearningPaused().value = paused
            PersonalSensing.shared.configure(scene: nil)
        case Config.PersonalLearningRetentionDays.key:
            guard case .int(let days) = value, days >= 0 else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.PersonalLearningRetentionDays().value = days
            LabController.shared.dataForgotten(all: false)
        case Config.personalLearningDeleteAllKey:
            PersonalContextMemory.shared.reset()
            PersonalSensing.shared.forget()
            PersonalLearner.shared.deleteAll()
            // 解析と学習の写し・版（その記録から作ったもの）も消す
            LabController.shared.dataForgotten(all: true)
        case _ where key.hasPrefix(Config.personalLearningForgetAppKeyPrefix):
            // そのアプリの記録と学習を消す（学習がオフでも、記録しないアプリでも）
            guard case .bool(true) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            PersonalSensing.shared.forget()
            PersonalLearner.shared.forgetApp(String(key.dropFirst(Config.personalLearningForgetAppKeyPrefix.count)))
            // 解析と学習の写しと、文章から作ったもの（索引・文体の説明・アダプタ）も無効にして消す
            LabController.shared.dataForgotten(all: false)
        case Config.PersonalAccessibilityPlaces.key:
            guard case .bool(let enabled) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.PersonalAccessibilityPlaces().value = enabled
        case Config.PersonalLearningSelfTuning.key:
            guard case .bool(let enabled) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.PersonalLearningSelfTuning().value = enabled
        case Config.personalLearningResetTuningKey:
            PersonalTuner.shared.reset()
        case Config.personalLearningExportKey:
            if case .string(let path) = value, !path.isEmpty {
                // 評価用（xpcprobe --export）: 指定した場所に書き出すだけ
                let url = try PersonalLearner.shared.export(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                try LabController.shared.exportAssets(beside: url)
            } else {
                let url = try PersonalLearner.shared.export()
                try LabController.shared.exportAssets(beside: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case _ where key.hasPrefix(Config.personalLearningWordKeyPrefix):
            // オフにすると忘れる
            if case .bool(false) = value {
                PersonalLearner.shared.forgetWord(id: String(key.dropFirst(Config.personalLearningWordKeyPrefix.count)))
            }
        case _ where key.hasPrefix(Config.personalLearningInputModeKeyPrefix):
            if case .bool(false) = value {
                PersonalLearner.shared.forgetInputMode(app: String(key.dropFirst(Config.personalLearningInputModeKeyPrefix.count)))
            }
        case _ where key.hasPrefix(Config.personalLearningAppKeyPrefix):
            guard case .bool(let enabled) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            if !enabled { PersonalSensing.shared.configure(scene: nil) }
            PersonalContextMemory.shared.reset()
            PersonalPrivacy.setExcluded(!enabled, app: String(key.dropFirst(Config.personalLearningAppKeyPrefix.count)))
        default:
            return false
        }
        return true
    }
}
