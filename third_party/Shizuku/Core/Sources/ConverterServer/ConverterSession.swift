import Core
import KanaKanjiConverterModuleWithDefaultDictionary

final class ConverterSession: SegmentManagerDelegate {
    static let conversionContextLength = 30
    static let replaceSuggestionContextLength = 100

    let manager: SegmentsManager
    let conversionSessionID: KanaKanjiConverter.ConversionSessionID
    var inputState: InputState = .none
    var inputLanguage: InputLanguage = .japanese
    var lastHandledKeyEventID: UInt64?
    var lastKeyEventResponse: ConverterServerResponse?
    private var context = ConverterTextContext()
    var windowBinding: WindowContextBinding? { context.windowBinding }
    var windowReference: WindowReference?
    var windowReferenceGeneration: UInt64?
    var config = ConverterSessionConfig(
        aiBackendPreference: .off,
        openAIModelName: Config.OpenAiModelName.default,
        openAIEndpoint: Config.OpenAiApiEndpoint.default,
        openAIAPIKey: .init(""),
        includeContextInAITransform: true
    )
    var pendingAssistanceReceipt: String?
    var magicTokens: [PersonalFragments.Token] = []
    var replaceSuggestions: [Candidate] = []
    var replaceSuggestionSelectionIndex: Int?
    /// llm-ime: キーイベントの処理後に始めた続き予測（結果を設定できたら true）
    var pendingCompletion: (eventID: UInt64, task: Task<Bool, Never>)?
    /// llm-ime: 場面学習（今の場面と入力中の統計）
    let personal = PersonalSessionState()
    var offers = OfferArbiter()
    var offerDecisions: [PersonalOfferTrust.Key: Bool] = [:]
    var emptyOfferScene: String?
    /// 学習をオフにしてもアプリ別の明示した声・Tabの設定は使う（記録はしない）。
    var activeAppID: String?
    var quoteCandidates: [String] = []
    var quoteGeneration = 0
    var retentionChecks: [String: (check: AssistanceRetention, scene: PersonalScene, id: Int64, kind: String)] = [:]
    /// llm-ime: 直前の文の清書の案（採用は Client が元の文を照合して置き換える）
    var cleanUpOffer: (original: String, text: String, scene: PersonalScene, usedReference: Bool)?
    /// llm-ime: 今出している続き予測・放置の続きが、画面の参考資料を使ったか
    var completionUsedReference = false
    var idleUsedReference = false

    func beginOfferStop() { offers.reset(); offerDecisions.removeAll() }

    init(
        manager: SegmentsManager,
        conversionSessionID: KanaKanjiConverter.ConversionSessionID
    ) {
        self.manager = manager
        self.conversionSessionID = conversionSessionID
        self.manager.delegate = self
    }

    func setContext(_ context: ConverterTextContext) {
        self.context = context
    }

    func setWindowBinding(_ binding: WindowContextBinding?) {
        context.windowBinding = binding
    }

    func getLeftSideContext(maxCount: Int) -> String? {
        guard let leftSideContext = context.leftSideContext else {
            return nil
        }
        if maxCount <= 40, PersonalLearner.isRecording, let scene = personal.scene,
           !PersonalPrivacy.isExcluded(app: scene.app), scene.shape == .code || scene.shape == .md {
            return String(PersonalMarkup.body(leftSideContext).suffix(maxCount))
        }
        return String(leftSideContext.suffix(maxCount))
    }

    func getRightSideContext(maxCount: Int) -> String? {
        guard let rightSideContext = context.rightSideContext else {
            return nil
        }
        return String(rightSideContext.prefix(maxCount))
    }

    func conversionLeftSideContext() -> String? {
        if PersonalLearner.isEnabled, let scene = personal.scene, !PersonalPrivacy.isExcluded(app: scene.app), scene.shape == .code || scene.shape == .md,
           let left = getLeftSideContext(maxCount: ConverterTextContext.leftTransportCharacterLimit) {
            return String(PersonalMarkup.body(left).suffix(Self.conversionContextLength))
        }
        return getLeftSideContext(maxCount: Self.conversionContextLength)
    }

    func replaceSuggestionPromptContext() -> String {
        let leftSideContext = getLeftSideContext(maxCount: Self.replaceSuggestionContextLength) ?? ""
        let rightSideContext = getRightSideContext(maxCount: Self.replaceSuggestionContextLength) ?? ""
        guard !leftSideContext.isEmpty || !rightSideContext.isEmpty else {
            return ""
        }
        return [
            leftSideContext.isEmpty ? nil : "Text before: ...\(leftSideContext)",
            rightSideContext.isEmpty ? nil : "Text after: \(rightSideContext)..."
        ]
        .compactMap(\.self)
        .joined(separator: "\n")
    }

    func clearReplaceSuggestions() {
        self.replaceSuggestions = []
        self.replaceSuggestionSelectionIndex = nil
    }

    func selectReplaceSuggestion(at index: Int) {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        replaceSuggestionSelectionIndex = min(max(0, index), replaceSuggestions.count - 1)
    }

    func selectNextReplaceSuggestion() {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        replaceSuggestionSelectionIndex = ((replaceSuggestionSelectionIndex ?? -1) + 1) % replaceSuggestions.count
    }

    func selectPreviousReplaceSuggestion() {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        let current = replaceSuggestionSelectionIndex ?? 0
        replaceSuggestionSelectionIndex = (current - 1 + replaceSuggestions.count) % replaceSuggestions.count
    }

    var selectedReplaceSuggestion: Candidate? {
        guard let replaceSuggestionSelectionIndex,
              replaceSuggestions.indices.contains(replaceSuggestionSelectionIndex) else {
            return nil
        }
        return replaceSuggestions[replaceSuggestionSelectionIndex]
    }
}
