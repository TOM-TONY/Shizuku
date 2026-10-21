import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

enum ConverterCandidateTransform {
    case hiragana
    case katakana
    case halfWidthKatakana
    case fullWidthRoman
    case halfWidthRoman
}

extension ConverterServer {
    @MainActor
    func makeResponse(
        for session: ConverterSession,
        inputState: InputState,
        handled: Bool = true,
        effects: [ConverterClientEffect] = [],
        settings: [ConverterSettingDescriptor] = [],
        responseInputState: ConverterInputState? = nil
    ) -> ConverterServerResponse {
        var response = ConverterServerResponse(
            handled: handled,
            effects: effects,
            inputState: responseInputState ?? ConverterInputState(inputState),
            inputLanguage: session.inputLanguage,
            settings: settings,
            snapshot: snapshot(for: session, inputState: inputState)
        )
        if inputState == .replaceSuggestion { response.magicFragments = magicFragments(session: session) }
        response.assistanceReceipt = session.pendingAssistanceReceipt
        session.pendingAssistanceReceipt = nil
        return response
    }

    @MainActor
    func snapshot(for session: ConverterSession, inputState: InputState) -> ConverterSessionSnapshot {
        let manager = session.manager
        if PersonalSensing.shared.microphoneActive {
            manager.clearNextTextCompletion()
            session.offers.invalidateGeneration()
            session.personal.skeletonOffer = nil
        }
        if manager.isEmpty, case .unicodeInput = inputState {
            // Unicode input は SegmentsManager の composition を使わず、Server が
            // 所有する inputState 自体を marked text として描画する。
        } else if manager.isEmpty {
            if let kind = session.offers.current?.kind, [.typo, .rewrite, .completion, .prediction].contains(kind) {
                session.beginOfferStop()
            }
            session.personal.rewriteOffer = nil
            return .empty
        }
        let markedText: ConverterMarkedText
        if inputState == .replaceSuggestion, let candidate = session.selectedReplaceSuggestion {
            markedText = ConverterMarkedText(
                elements: [.init(content: candidate.text, focus: .focused)],
                selectionRange: .init(location: candidate.text.count, length: 0)
            )
        } else {
            markedText = ConverterMarkedText(manager.getCurrentMarkedText(inputState: inputState))
        }
        let candidateWindow: ConverterCandidateWindow
        // llm-ime: 入力中の第 1 候補（言い直しを出すかを決める）
        var composingFirstCandidate: String?
        switch manager.getCurrentCandidateWindow(inputState: inputState) {
        case .hidden:
            candidateWindow = .hidden
        case .composing(let candidates, let selectionIndex):
            composingFirstCandidate = candidates.first?.text
            candidateWindow = .composing(
                manager.makeCandidatePresentations(candidates).map(ConverterCandidatePresentation.init),
                selectionIndex: selectionIndex
            )
        case .selecting(let candidates, let selectionIndex):
            candidateWindow = .selecting(
                manager.makeCandidatePresentations(candidates).map(ConverterCandidatePresentation.init),
                selectionIndex: selectionIndex
            )
        }
        let predictionCandidates: [ConverterPredictionCandidate]
        var nextTextCompletion: String?
        if inputState == .composing {
            // llm-ime: Tab で確定するのは タイプミス訂正（もしかして）→ 言い直し → 続き予測 → 辞書の予測 の順。
            // 続き予測は予測ウィンドウではなく、入力中の文字の後ろに薄い灰色で表示する（Client 側）
            let typoCandidates = manager.requestTypoCorrectionPredictionCandidates()
            let firstCandidate = composingFirstCandidate ?? (Config.LiveConversion().value ? markedText.elements.map(\.content).joined() : nil)
            let rewrite = automaticOfferAllowed(.rewrite, session: session)
                ? self.personalRewriteOffer(session: session, firstCandidate: firstCandidate, present: false) : nil
            var offers: [Offer] = []
            if !typoCandidates.isEmpty, automaticOfferAllowed(.typo, session: session) {
                offers.append(.init(.typo, text: typoCandidates[0].displayText, predictions: typoCandidates.map(ConverterPredictionCandidate.init)))
            }
            if let rewrite { offers.append(.init(.rewrite, text: rewrite, predictions: [.init(displayText: rewrite, appendText: "")])) }
            if let text = manager.nextTextCompletionFullText, automaticOfferAllowed(.completion, session: session) { offers.append(.init(.completion, text: text)) }
            let dictionary = manager.requestPredictionCandidates().map(ConverterPredictionCandidate.init)
            if let first = dictionary.first { offers.append(.init(.prediction, text: first.displayText, predictions: dictionary)) }
            let selected = chooseOffer(offers, session: session)
            if selected?.kind == .rewrite {
                _ = self.personalRewriteOffer(session: session, firstCandidate: firstCandidate)
            } else if let old = session.personal.rewriteOffer {
                if let scene = session.personal.scene { PersonalLearner.shared.recordRewriteOutcome(scene: scene, deleted: old.deleted, written: old.written, accepted: false) }
                session.personal.rewriteOffer = nil
            }
            nextTextCompletion = selected?.kind == .completion ? selected?.text : nil
            manager.capturePresentedNextTextCompletion(selected?.kind == .completion)
            predictionCandidates = selected?.predictions ?? []
            notePresentedOffer(session: session)
        } else {
            predictionCandidates = []
            session.personal.rewriteOffer = nil
        }
        return ConverterSessionSnapshot(
            markedText: markedText,
            candidateWindow: candidateWindow,
            predictionCandidates: predictionCandidates,
            replaceSuggestionCandidates: session.replaceSuggestions.map {
                ConverterCandidatePresentation(CandidatePresentation(candidate: $0))
            },
            replaceSuggestionSelectionIndex: session.replaceSuggestionSelectionIndex,
            isEmpty: manager.isEmpty,
            convertTarget: manager.convertTarget,
            nextTextCompletion: nextTextCompletion
        )
    }

    @MainActor
    static func makeSegmentsManager(kanaKanjiConverter: KanaKanjiConverter) -> SegmentsManager {
        CustomInputTableStore.registerIfExists()
        let containerURL = AppGroup.containerURL()
        let applicationDirectoryURL = AppGroup.memoryDirectoryURL()
        let typoCorrectionDirectoryURL = DebugTypoCorrectionWeights.modelDirectoryURL(
            applicationSupportDirectoryURL: applicationDirectoryURL.deletingLastPathComponent()
        )
        try? FileManager.default.createDirectory(
            at: applicationDirectoryURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: typoCorrectionDirectoryURL,
            withIntermediateDirectories: true
        )
        return SegmentsManager(
            kanaKanjiConverter: kanaKanjiConverter,
            applicationDirectoryURL: applicationDirectoryURL,
            containerURL: containerURL,
            context: .init(useZenzai: true, resourcesDirectoryURL: appResourcesDirectoryURL())
        )
    }

    static func appResourcesDirectoryURL() -> URL {
        if WindowContextTestRuntime.root != nil,
           let path = ProcessInfo.processInfo.environment["LLM_IME_WINDOW_TEST_RESOURCES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let executableURL = Bundle.main.executableURL {
            var directoryURL = executableURL.deletingLastPathComponent()
            while directoryURL.path != "/" {
                if directoryURL.lastPathComponent == "Contents" {
                    return directoryURL.appendingPathComponent("Resources", isDirectory: true)
                }
                directoryURL.deleteLastPathComponent()
            }
        }
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    @MainActor
    static func resolveInputStyle(_ inputStyle: ConverterInputStyle) -> InputStyle {
        if case .tableName(CustomInputTableStore.tableName) = inputStyle,
           !CustomInputTableStore.registerIfExists() {
            return .mapped(id: .defaultRomanToKana)
        }
        return inputStyle.inputStyle
    }

    @MainActor
    static func transformedCandidate(
        _ transform: ConverterCandidateTransform,
        manager: SegmentsManager,
        inputState: InputState
    ) -> Candidate {
        switch transform {
        case .hiragana:
            manager.getModifiedRubyCandidate(inputState: inputState) {
                $0.toHiragana()
            }
        case .katakana:
            manager.getModifiedRubyCandidate(inputState: inputState) {
                $0.toKatakana()
            }
        case .halfWidthKatakana:
            manager.getModifiedRubyCandidate(inputState: inputState) {
                $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            }
        case .fullWidthRoman:
            manager.getModifiedRomanCandidate(inputState: inputState) {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: true)!
            }
        case .halfWidthRoman:
            manager.getModifiedRomanCandidate(inputState: inputState) {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            }
        }
    }
}
