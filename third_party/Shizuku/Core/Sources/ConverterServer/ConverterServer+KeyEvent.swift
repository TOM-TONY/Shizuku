import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import LocalLLM

extension ConverterServer {
    @MainActor
    func handleKeyEvent(
        sessionID: String,
        request: ConverterKeyEventRequest
    ) throws -> ConverterServerResponse {
        let session = try getSession(sessionID)
        if let app = request.scene?.bundleID { session.activeAppID = app }
        WindowContextService.shared.prepare(request.context.windowBinding, session: session)
        WindowContextService.shared.noteKey()
        if request.eventID == session.lastHandledKeyEventID,
           let response = session.lastKeyEventResponse {
            let muted = PersonalSensing.shared.microphoneActive
            if muted {
                session.manager.clearNextTextCompletion()
                session.offers.invalidateGeneration()
                session.personal.skeletonOffer = nil
            }
            var filtered = AutomaticGenerationGate.response(response, microphoneActive: muted)
            if !AssistanceSettings.permits(.completion, app: (session.activeAppID ?? session.personal.scene?.app)) { filtered.snapshot.nextTextCompletion = nil }
            if let text = filtered.snapshot.nextTextCompletion,
               self.isDismissed(text, session: session) { filtered.snapshot.nextTextCompletion = nil }
            if !AssistanceSettings.permits(.prediction, app: (session.activeAppID ?? session.personal.scene?.app)) { filtered.snapshot.predictionCandidates = [] }
            session.lastKeyEventResponse = filtered
            return filtered
        }
        if let lastEventID = session.lastHandledKeyEventID,
           request.eventID < lastEventID {
            throw ConverterServerError.outOfOrderKeyEvent(
                expectedAfter: lastEventID,
                actual: request.eventID
            )
        }
        NextTextCompletionEngine.shared.beginKeyWork()
        defer { NextTextCompletionEngine.shared.endKeyWork() }
        if let activation = request.activation {
            session.config = activation.config
            session.inputLanguage = activation.inputLanguage
            if activation.inputLanguage == .english {
                session.manager.stopJapaneseInput()
            }
            session.manager.activate()
        }
        session.personal.draftChain.reset()
        session.setContext(request.context)
        // llm-ime: 場面学習（オフ、または IME 本体がメタ情報を送らなければ何もしない）
        self.preparePersonalization(session: session, request: request)
        if PersonalSensing.shared.microphoneActive { session.manager.clearNextTextCompletion() }
        PersonalTuningScheduler.shared.noteKeyEvent()
        // llm-ime: 解析と学習を実行中なら、すぐ止める（入力の遅延を増やさない）
        LabController.shared.noteActivity()
        PersonalEmbeddingService.shared.noteKey()
        Config.DebugPredictiveTyping().value = request.enablePredictiveTyping
        Config.DebugTypoCorrection().value = request.enableTypoCorrection
        // llm-ime: ライブ変換の設定はクライアント（IME）側で切り替えられる。ConverterServer が
        // App Group の設定を読めない環境では既定値（有効）のままになり、SegmentsManager が
        // ライブ変換として振る舞ってしまうため、リクエストの値をサーバー側にも反映する。
        if Config.LiveConversion().value != request.liveConversionEnabled {
            Config.LiveConversion().value = request.liveConversionEnabled
        }

        if request.enableOptionDirectFullWidthInput,
           let text = OptionDirectInputResolver.resolve(
            characters: request.optionDirectInputText,
            modifierFlags: request.event.modifierFlags,
            inputLanguage: session.inputLanguage,
            inputState: session.inputState,
            typeBackSlash: request.typeBackSlash
           ) {
            let response = ConverterServerResponse(
                effects: [.insertText(text)],
                inputState: ConverterInputState(session.inputState),
                inputLanguage: session.inputLanguage,
                snapshot: snapshot(for: session, inputState: session.inputState)
            )
            session.lastHandledKeyEventID = request.eventID
            session.lastKeyEventResponse = response
            return response
        }

        let userAction = UserAction.getUserAction(
            eventCore: request.event,
            inputLanguage: session.inputLanguage,
            typeBackSlash: request.typeBackSlash
        )
        let (clientAction, clientActionCallback) = session.inputState.event(
            eventCore: request.event,
            userAction: userAction,
            inputLanguage: session.inputLanguage,
            liveConversionEnabled: request.liveConversionEnabled,
            enableDebugWindow: request.enableDebugWindow,
            enableSuggestion: request.enableSuggestion
        )

        self.observeStallKey(session: session, request: request, action: clientAction)

        var effects: [ConverterClientEffect] = []
        var inputLanguage = session.inputLanguage
        let personalizing = session.manager.personalization != nil
        let rawInputBefore = personalizing ? session.manager.rawInputString : ""
        let typoSuggestionBefore = personalizing && session.offers.current?.kind == .typo ? session.offers.current?.text : nil
        let stallWasComposing = !session.manager.isEmpty
        let actionHandled = perform(
            clientAction,
            request: request,
            session: session,
            inputLanguage: &inputLanguage,
            effects: &effects
        )
        session.beginOfferStop()
        self.finishStallKey(session: session, wasComposing: stallWasComposing)
        guard actionHandled else {
            let response = ConverterServerResponse(
                handled: false,
                effects: effects,
                inputState: ConverterInputState(session.inputState),
                inputLanguage: inputLanguage,
                snapshot: snapshot(for: session, inputState: session.inputState)
            )
            session.lastHandledKeyEventID = request.eventID
            session.lastKeyEventResponse = response
            return response
        }

        var nextInputState = apply(
            clientActionCallback,
            currentInputState: session.inputState,
            compositionIsEmpty: session.manager.isEmpty
        )
        // llm-ime: 続き予測を Tab で確定すると入力が空になる
        if nextInputState == .composing, session.manager.isEmpty {
            nextInputState = .none
        }
        session.inputState = nextInputState
        if personalizing {
            self.finishPersonalization(
                session: session, action: clientAction, rawInputBefore: rawInputBefore, typoSuggestionBefore: typoSuggestionBefore
            )
        }
        scheduleNextTextCompletion(session: session, eventID: request.eventID)
        session.inputLanguage = inputLanguage
        var response = ConverterServerResponse(
            handled: !effects.contains(.fallthroughToApplication),
            effects: effects,
            inputState: ConverterInputState(nextInputState),
            inputLanguage: inputLanguage,
            snapshot: snapshot(for: session, inputState: nextInputState)
        )
        response.idleCompletionDelay = self.personalIdleDelay(session: session)
        session.lastHandledKeyEventID = request.eventID
        session.lastKeyEventResponse = response
        return response
    }

    @MainActor
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func perform(
        _ action: ClientAction,
        request: ConverterKeyEventRequest,
        session: ConverterSession,
        inputLanguage: inout InputLanguage,
        effects: inout [ConverterClientEffect]
    ) -> Bool {
        let manager = session.manager
        let inputState = session.inputState
        let inputStyle = Self.resolveInputStyle(session.inputLanguage == .english ? .direct : request.inputStyle)
        let leftSideContext = session.conversionLeftSideContext()
        switch action {
        case .consume:
            return true
        case .fallthrough:
            effects.append(.fallthroughToApplication)
            return true
        case .showCandidateWindow:
            manager.requestSetCandidateWindowState(visible: true)
        case .hideCandidateWindow:
            manager.requestSetCandidateWindowState(visible: false)
        case .appendToMarkedText(let text):
            manager.insertAtCursorPosition(text, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces):
            manager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let text):
            effects.append(.insertText(text))
        case .removeLastMarkedText:
            manager.deleteBackwardFromCursorPosition()
            manager.requestResettingSelection()
        case .commitMarkedText:
            let text = manager.commitMarkedText(inputState: inputState)
            if !text.isEmpty {
                effects.append(.insertText(text))
            }
        case .editSegment(let count):
            manager.editSegment(count: count)
        case .enterFirstCandidatePreviewMode:
            manager.insertCompositionSeparator(inputStyle: inputStyle, skipUpdate: true)
            manager.updateForFirstCandidate()
            manager.requestSetCandidateWindowState(visible: false)
        case .enterCandidateSelectionMode:
            manager.insertCompositionSeparator(inputStyle: inputStyle, skipUpdate: true)
            manager.update(requestRichCandidates: true)
        case .submitSelectedCandidate:
            submitSelectedCandidate(manager: manager, leftSideContext: leftSideContext, effects: &effects)
        case .selectNextCandidate:
            manager.requestSelectingNextCandidate()
        case .selectPrevCandidate:
            manager.requestSelectingPrevCandidate()
        case .selectNumberCandidate(let number):
            manager.requestSelectingRow(request.visibleCandidateStartIndex + number - 1)
            submitSelectedCandidate(manager: manager, leftSideContext: leftSideContext, effects: &effects)
            manager.requestResettingSelection()
        case .selectInputLanguage(let language):
            inputLanguage = language
            effects.append(.switchInputLanguage(language))
        case .commitMarkedTextAndSelectInputLanguage(let language):
            let text = manager.commitMarkedText(inputState: inputState)
            if !text.isEmpty {
                effects.append(.insertText(text))
            }
            inputLanguage = language
            effects.append(.switchInputLanguage(language))
        case .commitMarkedTextAndAppendToMarkedText(let text):
            commitMarkedTextAndContinue(
                manager: manager,
                inputState: inputState,
                effects: &effects
            )
            manager.insertAtCursorPosition(text, inputStyle: inputStyle)
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            commitMarkedTextAndContinue(
                manager: manager,
                inputState: inputState,
                effects: &effects
            )
            manager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .enableDebugWindow:
            manager.requestDebugWindowMode(enabled: true)
        case .disableDebugWindow:
            manager.requestDebugWindowMode(enabled: false)
        case .forgetMemory:
            manager.forgetMemory()
        case .submitKatakanaCandidate:
            submitTransformedCandidate(.katakana, manager: manager, inputState: inputState, leftSideContext: leftSideContext, effects: &effects)
        case .submitHiraganaCandidate:
            submitTransformedCandidate(.hiragana, manager: manager, inputState: inputState, leftSideContext: leftSideContext, effects: &effects)
        case .submitHankakuKatakanaCandidate:
            submitTransformedCandidate(.halfWidthKatakana, manager: manager, inputState: inputState, leftSideContext: leftSideContext, effects: &effects)
        case .submitFullWidthRomanCandidate:
            submitTransformedCandidate(.fullWidthRoman, manager: manager, inputState: inputState, leftSideContext: leftSideContext, effects: &effects)
        case .submitHalfWidthRomanCandidate:
            submitTransformedCandidate(.halfWidthRoman, manager: manager, inputState: inputState, leftSideContext: leftSideContext, effects: &effects)
        case .requestPredictiveSuggestion:
            manager.insertAtCursorPosition("つづき", inputStyle: inputStyle)
            effects.append(.requestReplaceSuggestion)
        case .acceptPredictionCandidate:
            if !PersonalLearner.isRecording || !PersonalLearner.shared.hasOfferHistory {
                // 学習オフと記録ゼロは従来の確定経路をそのまま保つ。
                if manager.requestTypoCorrectionPredictionCandidates().isEmpty,
                   let text = self.acceptPersonalRewrite(session: session, leftSideContext: leftSideContext ?? "") {
                    effects.append(.insertText(text))
                } else if manager.requestTypoCorrectionPredictionCandidates().isEmpty,
                          let text = manager.acceptNextTextCompletion(leftSideContext: leftSideContext ?? "") {
                    effects.append(.insertText(text))
                } else { manager.acceptPredictionCandidate() }
                break
            }
            // 司会が実際に表示したものを採る。遅れて来た見えない上位候補は採らない。
            switch session.offers.current?.kind {
            case .rewrite:
                if let text = self.acceptPersonalRewrite(session: session, leftSideContext: leftSideContext ?? "") {
                effects.append(.insertText(text))
                }
            case .completion:
                if let text = manager.acceptNextTextCompletion(leftSideContext: leftSideContext ?? "", displayedOnly: true) {
                effects.append(.insertText(text))
                }
            case .typo:
                if let p = session.offers.current?.predictions.first {
                    manager.acceptTypoCorrectionPredictionCandidate(.init(displayText: p.displayText, appendText: p.appendText, deleteCount: p.deleteCount))
                }
            case .prediction: manager.acceptPredictionCandidate(allowTypo: false)
            default: break
            }
        case .requestReplaceSuggestion:
            session.clearReplaceSuggestions()
            effects.append(.requestReplaceSuggestion)
        case .selectNextReplaceSuggestionCandidate:
            PersonalLearner.shared.recordReaction(kind: "ai_cycled", scene: session.personal.scene)
            session.selectNextReplaceSuggestion()
        case .selectPrevReplaceSuggestionCandidate:
            PersonalLearner.shared.recordReaction(kind: "ai_cycled", scene: session.personal.scene)
            session.selectPreviousReplaceSuggestion()
        case .submitReplaceSuggestionCandidate:
            _ = submitSelectedReplaceSuggestion(session: session, effects: &effects)
        case .hideReplaceSuggestionWindow:
            PersonalLearner.shared.recordReaction(kind: "ai_cancelled", scene: session.personal.scene)
            if let scene = session.personal.scene {
                for candidate in session.replaceSuggestions { DismissedOfferStore.shared.remember(candidate.text, scene: scene) }
            }
            session.clearReplaceSuggestions()
            effects.append(.hideReplaceSuggestionWindow)
        case .showPromptInputWindow:
            effects.append(.showPromptInputWindow)
        case .transformSelectedText(let selectedText, let prompt):
            effects.append(.transformSelectedText(selectedText, prompt))
        case .enterUnicodeInputMode, .appendToUnicodeInput, .removeLastUnicodeInput, .cancelUnicodeInput:
            return true
        case .submitUnicodeInput(let codePoint):
            if let scalar = UInt32(codePoint, radix: 16), let unicodeScalar = Unicode.Scalar(scalar) {
                effects.append(.insertText(String(Character(unicodeScalar))))
            }
        case .submitSelectedCandidateAndEnterUnicodeInputMode:
            submitSelectedCandidate(manager: manager, leftSideContext: leftSideContext, effects: &effects)
            if !manager.isEmpty {
                effects.append(.insertText(manager.convertTarget))
                manager.stopComposition()
            }
        case .stopComposition:
            manager.stopComposition()
        }
        return true
    }

    @MainActor
    func apply(
        _ callback: ClientActionCallback,
        currentInputState: InputState,
        compositionIsEmpty: Bool
    ) -> InputState {
        switch callback {
        case .fallthrough:
            return currentInputState
        case .transition(let inputState):
            return inputState
        case .basedOnBackspace(let ifIsEmpty, let ifIsNotEmpty),
             .basedOnSubmitCandidate(let ifIsEmpty, let ifIsNotEmpty):
            return compositionIsEmpty ? ifIsEmpty : ifIsNotEmpty
        }
    }

    @MainActor
    func commitMarkedTextAndContinue(
        manager: SegmentsManager,
        inputState: InputState,
        effects: inout [ConverterClientEffect]
    ) {
        let text = manager.commitMarkedText(inputState: inputState)
        if !text.isEmpty {
            effects.append(.insertText(text))
        }
    }

    @MainActor
    func submitSelectedCandidate(
        manager: SegmentsManager,
        leftSideContext: String?,
        effects: inout [ConverterClientEffect]
    ) {
        guard let candidate = manager.selectedCandidate else {
            return
        }
        manager.prefixCandidateCommited(candidate, leftSideContext: leftSideContext ?? "")
        effects.append(.insertText(candidate.text))
    }

    @MainActor
    func submitTransformedCandidate(
        _ transform: ConverterCandidateTransform,
        manager: SegmentsManager,
        inputState: InputState,
        leftSideContext: String?,
        effects: inout [ConverterClientEffect]
    ) {
        let candidate = Self.transformedCandidate(transform, manager: manager, inputState: inputState)
        manager.prefixCandidateCommited(candidate, leftSideContext: leftSideContext ?? "", kind: .transform)
        effects.append(.insertText(candidate.text))
    }

    @MainActor
    func requestReplaceSuggestion(
        session: ConverterSession
    ) async throws {
        session.clearReplaceSuggestions()
        guard !session.manager.isEmpty else {
            return
        }
        let backend: AIBackend
        switch session.config.aiBackendPreference {
        case .off:
            return
        case .foundationModels:
            backend = .foundationModels
        case .openAI:
            backend = .openAI
        case .localLLM:
            backend = .localLLM
        }
        let composingText = session.manager.convertTarget
        switch session.manager.getCurrentCandidateWindow(inputState: .composing) {
        case .composing(let candidates, _), .selecting(let candidates, _):
            session.magicTokens = candidates.first?.data.map { .init(surface: $0.word, reading: $0.ruby) } ?? []
        case .hidden: session.magicTokens = []
        }
        let predictions: [String]
        if backend == .localLLM {
            guard Self.localModelAllowed else { throw NSError(domain: "Shizuku.resources", code: 1, userInfo: [NSLocalizedDescriptionKey: "現在の資源の段ではこのモデルを自動選択しません。設定でモデルを選んでください。"]) }
            // llm-ime: ローカル LLM（Gemma 4）で、設定のスタイル指示に沿った書き換え候補を作る
            let leftContext = session.config.includeContextInAITransform
                ? (session.getLeftSideContext(maxCount: ConverterSession.replaceSuggestionContextLength) ?? "")
                : ""
            // llm-ime: 場面学習。この場面で本人が前に書いた似た文を、書き方の手本として渡す（キーワードから本人の文へ）
            await LabController.shared.prepareForLocalModel()
            let revision = LabController.shared.personalizationRevision
            let forgetGeneration = PersonalLearner.shared.forgetGeneration
            let examples = try self.personalMagicConversionExamples(session: session, leftContext: leftContext)
            let personalization = LabController.shared.personalization(
                scene: session.manager.personalization == nil ? nil : session.personal.scene,
                vector: PersonalEmbeddingService.shared.queryVector(for: session), model: Self.localLLMModelDirectory)
            let magicReference = await self.llmWindowReference(session: session, query: leftContext + composingText)
            let output = try await LocalLLMEngine.shared.respond(
                system: LocalLLMPrompts.suggestionSystem,
                user: LocalLLMPrompts.suggestionUserPrompt(
                    leftContext: leftContext,
                    target: composingText,
                    style: Config.MagicConversionStyle().value.isEmpty ? personalization.style ?? "" : Config.MagicConversionStyle().value,
                    examples: examples,
                    reference: magicReference
                ),
                modelDirectory: Self.localLLMModelDirectory,
                maxTokens: 200,
                adapterDirectory: personalization.adapter, usageFeature: "magic"
            )
            guard revision == LabController.shared.personalizationRevision, forgetGeneration == PersonalLearner.shared.forgetGeneration else { return }
            predictions = LocalLLMPrompts.parseSuggestions(output).map {
                PersonalLearner.shared.normalizedGeneratedText($0, scene: session.personal.scene, route: .magic)
            }.filter { WindowReferenceGeneration.permits($0, draft: leftContext + composingText, reference: magicReference) }
        } else {
            let prompt = session.config.includeContextInAITransform ? session.replaceSuggestionPromptContext() : ""
            let request = OpenAIRequest(
                prompt: prompt,
                target: composingText,
                modelName: session.config.openAIModelName.isEmpty ? Config.OpenAiModelName.default : session.config.openAIModelName
            )
            predictions = try await AIClient.sendRequest(
                request,
                backend: backend,
                apiKey: session.config.openAIAPIKey.value,
                apiEndpoint: session.config.openAIEndpoint.isEmpty ? Config.OpenAiApiEndpoint.default : session.config.openAIEndpoint
            )
        }
        guard session.manager.convertTarget == composingText else {
            return
        }
        session.replaceSuggestions = predictions.filter { !DismissedOfferStore.shared.suppresses($0, scene: session.personal.scene) }.map { text in
            Candidate(
                text: text,
                value: PValue(0),
                composingCount: .surfaceCount(composingText.count),
                lastMid: 0,
                data: [],
                actions: [],
                inputable: true
            )
        }
        if !session.replaceSuggestions.isEmpty {
            session.replaceSuggestionSelectionIndex = 0
        }
    }

    @MainActor
    func submitSelectedReplaceSuggestion(
        session: ConverterSession,
        effects: inout [ConverterClientEffect]
    ) -> Bool {
        guard let candidate = session.selectedReplaceSuggestion else {
            return false
        }
        if session.manager.personalization != nil {
            // llm-ime: いい感じ変換の候補を確定した（場面学習の記録）
            let previousCommit = session.personal.lastCommit?.0
            session.recordPersonalCommit(
                kind: "ai", reading: session.manager.convertTarget.toKatakana(), surface: candidate.text, defaultSurface: nil,
                rank: session.replaceSuggestionSelectionIndex, leftContext: session.getLeftSideContext(maxCount: 20) ?? ""
            )
            session.personal.resetComposition()
            session.personal.compositionID = 0
            if PersonalLearner.isRecording, let id = session.personal.lastCommit?.0, id != previousCommit, let scene = session.personal.scene {
                session.pendingAssistanceReceipt = registerRetention(text: candidate.text, kind: "ai", id: id, scene: scene, session: session)
            }
        }
        effects.append(.insertText(candidate.text))
        session.manager.stopComposition()
        session.clearReplaceSuggestions()
        return true
    }
}

extension ConverterServer {
    /// llm-ime: 入力が止まったときの処理を非同期に行う。結果はセッションの SegmentsManager に入り、クライアントが
    /// `.completion(.await)` で受け取った snapshot に出る。
    /// 1. 変換（スペース）と同じ第 1 候補を求めて、入力中の候補の表示（ライブ変換オフの青い枠）を差し替える
    /// 2. 続き予測（設定がオンのとき）。土台は 1 の候補
    /// 打鍵が続いている間は行わない（続き予測の計算中か、少し待つ間に次のキーが来たら捨てる。変換は主スレッドで行うため）
    @MainActor
    func scheduleNextTextCompletion(session: ConverterSession, eventID: UInt64) {
        guard session.inputState == .composing else {
            if session.pendingCompletion != nil {
                NextTextCompletionEngine.shared.cancel()
            }
            session.pendingCompletion = nil
            return
        }
        let rawRequest = session.manager.makeNextTextCompletionRequest()
        let muted = PersonalSensing.shared.muteGeneration(kind: "completion", scene: session.personal.scene, record: rawRequest != nil)
        if muted {
            NextTextCompletionEngine.shared.cancel()
            session.manager.clearNextTextCompletion()
        }
        // マイクで止めるのは生成だけ。下の第1候補の再計算は常に従来の経路へ通す。
        let allowed = rawRequest != nil && !muted && automaticOfferAllowed(.completion, session: session)
        let request = allowed ? self.personalCompletionRequest(session: session, request: rawRequest) : nil
        if request == nil, session.pendingCompletion != nil {
            NextTextCompletionEngine.shared.cancel()
        }
        let conversionSessionID = session.conversionSessionID
        // llm-ime: 場面学習の本人の文の手本（オフなら空で、従来どおり）と、自己調整したしきい値（なければ既定）
        let prefix = request.map { self.personalCompletionPrefix(session: session, context: $0.context) } ?? ""
        let threshold = request == nil ? nil : self.personalTunedValue(.completionThreshold, session: session).map { Float($0) }
        let referenceGeneration = session.windowReferenceGeneration
        let capturedReference = session.windowReference
        let task = Task { @MainActor [weak session] () -> Bool in
            let reference = await WindowReferenceRetrieval.shared.text(reference: capturedReference, query: request?.context ?? "")
            guard !Task.isCancelled, let currentSession = session, currentSession.lastHandledKeyEventID == eventID,
                  await WindowContextService.shared.isCurrent(currentSession, generation: referenceGeneration) else { return false }

            var suggestion: NextTextCompletionEngine.Suggestion?
            if let request, session?.offers.mayPrepare(.completion) == true {
                suggestion = await AutomaticGenerationGate.generate(microphoneActive: { PersonalSensing.shared.microphoneActive }) {
                    await NextTextCompletionEngine.shared.complete(
                        context: capturedReference?.extendedContext(request.context) ?? request.context,
                        minLogProb: threshold, leadingPunctuation: false, prefix: prefix, reference: reference
                    )
                }
            } else {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let session, session.lastHandledKeyEventID == eventID,
                  await WindowContextService.shared.isCurrent(session, generation: referenceGeneration),
                  let base = (try? self.kanaKanjiConverter.withSession(conversionSessionID) {
                      session.manager.refineFirstCandidate()
                  }) ?? nil else {
                return false
            }
            guard let request, var completion = suggestion else {
                // 入力中の候補の表示だけが変わりうる
                return true
            }
            var finalRequest = request
            if base.text != request.base {
                // 続き予測の土台は、変換（スペース）と同じ第 1 候補にする。違えば、その候補の続きを予測し直す
                // （文脈の前半はキャッシュが効くので速い）
                guard let redo = self.personalCompletionRequest(session: session, request: session.manager.makeNextTextCompletionRequest(base: base)),
                      let redone = await AutomaticGenerationGate.generate(microphoneActive: { PersonalSensing.shared.microphoneActive }, {
                          await NextTextCompletionEngine.shared.complete(
                            context: capturedReference?.extendedContext(redo.context) ?? redo.context,
                            minLogProb: threshold, leadingPunctuation: false, prefix: prefix, reference: reference
                          )
                      }),
                      session.lastHandledKeyEventID == eventID,
                      await WindowContextService.shared.isCurrent(session, generation: referenceGeneration) else {
                    return true
                }
                finalRequest = redo
                completion = redone
            }
            let shown = (try? self.kanaKanjiConverter.withSession(conversionSessionID) {
                session.manager.setNextTextCompletion(completion.text, base: base, for: finalRequest)
            }) ?? false
            if shown { session.completionUsedReference = !reference.isEmpty }
            if PersonalSensing.shared.microphoneActive { session.manager.clearNextTextCompletion(); return false }
            return shown
        }
        session.pendingCompletion = (eventID, task)
    }

    @MainActor
    func handle(_ command: ConverterCompletionCommand, session: ConverterSession) async throws -> ConverterServerResponse {
        switch command {
        case .assistance(let event, let key, let hash, let count):
            let permitted = ["verb_tab_one", "verb_tab_all", "verb_esc", "verb_undo", "verb_summon", "tab_owner", "quote_shown",
                             "cleanup_shown", "cleanup_accepted", "cleanup_undone"]
            guard permitted.contains(event) else { return .init(snapshot: .empty) }
            let scene = key.flatMap(PersonalScene.init(key:)) ?? session.personal.scene
            if event == "verb_esc", let hash, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) {
                session.personal.dismissedOffers.insert(hash)
                self.rememberDismissed(hash: hash, session: session, scene: scene)
                if let offer = session.cleanUpOffer, AssistanceVerbs.fingerprint(offer.text) == hash {
                    if PersonalLearner.isRecording { PersonalLearner.shared.recordReaction(kind: "cleanup_dismissed", scene: offer.scene) }
                    session.cleanUpOffer = nil
                }
                session.manager.clearNextTextCompletion(); session.offers.reset()
                session.personal.skeletonOffer = nil
                NextTextCompletionEngine.shared.cancel()
            }
            if event == "cleanup_shown" || event == "cleanup_accepted", let offer = session.cleanUpOffer {
                WindowEffectRecorder.note(kind: "cleanup", used: offer.usedReference, accepted: event == "cleanup_accepted", scene: offer.scene)
            }
            if event == "cleanup_accepted" || event == "cleanup_undone" { session.cleanUpOffer = nil }
            if event == "tab_owner", let scene { PersonalLearner.shared.recordTabOwner(scene: scene) }
            else { PersonalLearner.shared.recordReaction(kind: event, scene: scene, a: hash, n: count.map { max(0, min(10000, $0)) }) }
            return .init(snapshot: .empty)
        case .teach(let text, let observation, let left, let right):
            var response = ConverterServerResponse(snapshot: .empty)
            response.teachingResult = .init(count: 0)
            guard PersonalLearner.isRecording, let app = observation.bundleID, !PersonalPrivacy.isExcluded(app: app),
                  var scene = PersonalScene.classify(observation: observation, leftContext: String(left.suffix(2000)), rightContext: right) else { return response }
            if let shape = PersonalMarkup.shape(left: left, right: right ?? "", monospaced: observation.monospaced == true) { scene.shape = shape; scene.reply = false }
            if let previous = session.personal.scene, previous.app == app { scene.place = previous.place; scene.recipient = previous.recipient }
            let result = PersonalLearner.shared.teach(text, scene: scene)
            response.teachingResult = .init(count: result.count, token: result.token)
            return response
        case .undoTeach(let token):
            var response = ConverterServerResponse(snapshot: .empty)
            response.teachingResult = .init(count: PersonalLearner.shared.undoTeaching(token: token))
            return response
        case .quotes(let observation, let left, let right):
            return quoteChoices(session: session, observation: observation, left: String(left.suffix(2000)), right: right)
        case .acceptQuote(let text):
            return try acceptQuote(text, session: session)
        case .retained(let token, let left, let complete):
            return checkRetention(token: token, left: left.map { String($0.suffix(2000)) }, complete: complete, session: session)
        case .draft(let leftContext):
            WindowContextService.shared.prepare(session.windowBinding, session: session)
            let referenceGeneration = session.windowReferenceGeneration
            let inputID = session.lastHandledKeyEventID
            guard Config.NextTextCompletion().value, Config.NextTextCompletionIdle().value, session.manager.isEmpty,
                  !leftContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !PersonalSensing.shared.muteGeneration(kind: "idle", scene: session.personal.scene),
                  automaticOfferAllowed(.idle, session: session), session.offers.mayPrepare(.idle) else {
                return try kanaKanjiConverter.withSession(session.conversionSessionID) {
                    makeResponse(for: session, inputState: session.inputState)
                }
            }
            guard session.personal.draftChain.permits(contextHash: LabUpperBound.hash(leftContext), limit: ResourceBudget.current.idleSentences)
            else { return makeResponse(for: session, inputState: session.inputState) }
            // Client の左文脈が短いアプリでは、画面から読んだ欄の全文で長くする
            let draftLeft = session.windowReference?.extendedContext(String(leftContext.suffix(ConverterTextContext.leftTransportCharacterLimit)))
                ?? String(leftContext.suffix(ConverterTextContext.leftTransportCharacterLimit))
            let draftContext = self.personalContinuationContext(session: session, left: draftLeft)
            let reference = await WindowReferenceRetrieval.shared.text(reference: session.windowReference, query: draftContext)
            guard session.lastHandledKeyEventID == inputID, await WindowContextService.shared.isCurrent(session, generation: referenceGeneration) else { return .init(snapshot: .empty) }
            let rawSentence = await NextTextCompletionEngine.shared.continueSentence(

                context: draftContext,
                prefix: self.personalCompletionPrefix(session: session, context: draftContext),
                reference: reference
            )
            guard session.lastHandledKeyEventID == inputID, await WindowContextService.shared.isCurrent(session, generation: referenceGeneration) else { return .init(snapshot: .empty) }
            let singleLine = session.personal.scene.map { $0.shape == .line || $0.aiDirected } ?? false
            let sentence = rawSentence.map {
                AssistanceVerbs.inlineContinuation(PersonalLearner.shared.normalizedGeneratedText($0, scene: session.personal.scene, route: .draft),
                                                   left: leftContext, singleLine: singleLine)
            }
            if let sentence, !sentence.isEmpty, !PersonalSensing.shared.microphoneActive {
                session.personal.draftChain.emitted(nextContextHash: LabUpperBound.hash(leftContext + sentence))
            }
            return try kanaKanjiConverter.withSession(session.conversionSessionID) {
                var response = makeResponse(for: session, inputState: session.inputState)
                if session.manager.isEmpty, !PersonalSensing.shared.microphoneActive, let sentence {
                    session.idleUsedReference = !reference.isEmpty
                    response.windowReferenceUsed = !reference.isEmpty
                    response.snapshot.nextTextCompletion = emptyOffer(.idle, text: sentence, session: session)
                    response.windowContextReceipt = WindowContextService.shared.receipt(for: session)
                }
                return response
            }
        case .idle(let leftContext):
            WindowContextService.shared.prepare(session.windowBinding, session: session)
            let referenceGeneration = session.windowReferenceGeneration
            let inputID = session.lastHandledKeyEventID
            PersonalSensing.shared.idleTimer(scene: session.personal.scene)
            // 何も入力していない状態の続き予測（入力中の文字があれば行わない）
            guard Config.NextTextCompletion().value, Config.NextTextCompletionIdle().value, session.manager.isEmpty,
                  !leftContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !PersonalSensing.shared.muteGeneration(kind: "idle", scene: session.personal.scene),
                  automaticOfferAllowed(.idle, session: session), session.offers.mayPrepare(.idle) else {
                return try kanaKanjiConverter.withSession(session.conversionSessionID) {
                    makeResponse(for: session, inputState: session.inputState)
                }
            }
            let idleLeft = session.windowReference?.extendedContext(String(leftContext.suffix(ConverterTextContext.leftTransportCharacterLimit)))
                ?? String(leftContext.suffix(ConverterTextContext.leftTransportCharacterLimit))
            let idleContext = self.personalContinuationContext(session: session, left: idleLeft)
            let reference = await WindowReferenceRetrieval.shared.text(reference: session.windowReference, query: idleContext)
            guard session.lastHandledKeyEventID == inputID, await WindowContextService.shared.isCurrent(session, generation: referenceGeneration) else { return .init(snapshot: .empty) }
            let suggestion = await NextTextCompletionEngine.shared.complete(

                context: idleContext,
                minLogProb: NextTextCompletionEngine.idleMinLogProb,
                prefix: self.personalCompletionPrefix(session: session, context: idleContext),
                reference: reference
            )
            guard session.lastHandledKeyEventID == inputID, await WindowContextService.shared.isCurrent(session, generation: referenceGeneration) else { return .init(snapshot: .empty) }
            let singleLine = session.personal.scene.map { $0.shape == .line || $0.aiDirected } ?? false
            let text = suggestion.map {
                AssistanceVerbs.inlineContinuation(PersonalLearner.shared.normalizedGeneratedText($0.text, scene: session.personal.scene, route: .idle),
                                                   left: leftContext, singleLine: singleLine)
            }
            return try kanaKanjiConverter.withSession(session.conversionSessionID) {
                var response = makeResponse(for: session, inputState: session.inputState)
                if session.manager.isEmpty, !PersonalSensing.shared.microphoneActive, let text {
                    session.idleUsedReference = !reference.isEmpty
                    response.windowReferenceUsed = !reference.isEmpty
                    response.snapshot.nextTextCompletion = emptyOffer(.idle, text: text, session: session)
                    response.windowContextReceipt = WindowContextService.shared.receipt(for: session)
                }
                return response
            }
        case .windowHint(let text):
            var response = ConverterServerResponse(snapshot: .empty)
            response.windowHint = await self.windowHint(text: text, session: session)
            return response
        case .skeleton(let observation):
            if PersonalLearner.isRecording, let app = observation.bundleID, !PersonalPrivacy.isExcluded(app: app),
               observation.documentLength == 0 {
                self.noteStallEntry(session: session)
            }
            let text = await self.personalSkeleton(session: session, observation: observation)
            return try kanaKanjiConverter.withSession(session.conversionSessionID) {
                var response = makeResponse(for: session, inputState: session.inputState)
                if session.manager.isEmpty, let text {
                    response.snapshot.nextTextCompletion = text
                }
                return response
            }
        case .nextPrompt(let observation, let round):
            let result = await self.emptyFieldSuggestion(session: session, observation: observation, round: round)
            return try kanaKanjiConverter.withSession(session.conversionSessionID) {
                var response = makeResponse(for: session, inputState: session.inputState)
                response.nextPromptPending = result.pending
                response.emptyFieldLineRect = result.anchor
                if session.manager.isEmpty, let text = result.text {
                    response.windowReferenceUsed = result.fromScreen
                    response.snapshot.nextTextCompletion = text
                }
                return response
            }
        case .idleAccepted(let text):
            self.notePersonalIdleCompletion(session: session, accepted: text)
            return try kanaKanjiConverter.withSession(session.conversionSessionID) {
                makeResponse(for: session, inputState: session.inputState)
            }
        case .await(let eventID):
            if let pending = session.pendingCompletion, pending.eventID == eventID {
                _ = await pending.task.value
            }
            return try kanaKanjiConverter.withSession(session.conversionSessionID) {
                makeResponse(for: session, inputState: session.inputState)
            }
        }
    }
}

extension ConverterServer {
    /// llm-ime: 設定で選んだローカル LLM のモデル（12B / 31B）
    /// 選んだ大きさのモデルが入っていなければ、入っている方を使う（配布版で一部のモデルだけ入れた場合）
    /// 設定でモデルを選んでいればそれ（使えなければ下の順）。選んでいなければ 31B（高品質の設定がオフなら 12B）。
    /// どれもなければ、入っている使えるモデルの先頭
    static var localLLMModelDirectory: URL {
        let preferLarge = (Config.object(forKey: Config.LocalLLMLargeModel.key) as? Bool) ?? ResourceBudget.current.allow31B
        let defaults = preferLarge
            ? [LocalLLMEngine.largeModelName, LocalLLMEngine.standardModelName]
            : [LocalLLMEngine.standardModelName, LocalLLMEngine.largeModelName]
        return ModelCatalog.resolve(selected: Config.LocalLLMModel().value, kind: .chat, fallbacks: defaults)
            ?? LocalLLMEngine.modelDirectoryURL(name: defaults[0])
    }

    static var localModelAllowed: Bool {
        if !Config.LocalLLMModel().value.isEmpty || Config.object(forKey: Config.LocalLLMLargeModel.key) is Bool { return true }
        let name = Self.localLLMModelDirectory.lastPathComponent
        return name == LocalLLMEngine.largeModelName ? ResourceBudget.current.allow31B
            : name == LocalLLMEngine.standardModelName ? ResourceBudget.current.allow12B : true
    }

    /// llm-ime: ローカル LLM（Gemma 4, MLX）への依頼を処理する。
    @MainActor
    func handle(_ command: ConverterLocalLLMCommand, session: ConverterSession) async -> ConverterServerResponse {
        guard Self.localModelAllowed else {
            var response = makeResponse(for: session, inputState: session.inputState)
            response.localLLMResult = .init(error: "現在の資源の段ではこのモデルを自動選択しません。設定でモデルを選んでください。")
            return response
        }
        // llm-ime: ローカル LLM を使う間は、解析と学習を止める
        await LabController.shared.prepareForLocalModel()
        let result: ConverterLocalLLMResult
        switch command {
        case .transform(let text, let instruction, let before, let after):
            let reference = await self.llmWindowReference(session: session, query: before + text)
            do {
                let output = try await LocalLLMEngine.shared.respond(
                    system: LocalLLMPrompts.transformSystem,
                    user: LocalLLMPrompts.transformUserPrompt(text: text, instruction: instruction, before: before, after: after, reference: reference),
                    modelDirectory: Self.localLLMModelDirectory,
                    maxTokens: max(256, text.count * 3),
                    thinking: Config.LocalLLMThinking().value, usageFeature: "rewrite"
                )
                let transformed = PersonalLearner.shared.normalizedGeneratedText(output, scene: session.personal.scene, route: .transform)
                result = WindowReferenceGeneration.permits(transformed, draft: before + text + instruction, reference: reference)
                    ? .init(text: transformed) : .init(error: "画面の内容から本人が書いていない約束や数字を足したため表示しません。もう一度試してください。")
            } catch {
                result = .init(error: error.localizedDescription)
            }
        case .proofread(let text, let before, let after):
            let reference = await self.llmWindowReference(session: session, query: before + text)
            do {
                let output = try await LocalLLMEngine.shared.respond(
                    system: LocalLLMPrompts.proofreadSystem,
                    user: LocalLLMPrompts.proofreadUserPrompt(text: text, before: before, after: after,
                        protectedTerms: PersonalLearner.shared.protectedHonorifics(scene: session.personal.scene), reference: reference),
                    modelDirectory: Self.localLLMModelDirectory,
                    maxTokens: max(256, text.count * 2),
                    thinking: Config.LocalLLMThinking().value, usageFeature: "proofread"
                )
                let corrected = PersonalGeneratedText.apply(LocalLLMPrompts.cleanProofreadOutput(output), route: .proofread,
                    enabled: PersonalLearner.isEnabled, plan: nil)
                // 添削は一部の文字を直すだけなので、長さが大きく変わった結果（説明文を返した・途中で切れた等）は
                // 修正案として出さない（全文の削除や置き換えに見えてしまうため）
                if abs(corrected.count - text.count) > max(10, text.count / 3) {
                    result = .init(error: "添削の結果が元の文章と大きく異なるため表示しません。もう一度試してください。")
                } else {
                    result = .init(text: corrected)
                }
            } catch {
                result = .init(error: error.localizedDescription)
            }
        case .cleanUp(let text, let before, let automatic):
            result = await self.cleanUp(text: text, before: before, automatic: automatic, session: session)
        case .preload:
            await LocalLLMEngine.shared.preload(directory: Self.localLLMModelDirectory)
            result = .init(text: "")
        }
        var response = makeResponse(for: session, inputState: session.inputState)
        response.localLLMResult = result
        return response
    }
}
