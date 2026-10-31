import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public final class SegmentsManager {
    private static let textReplacer = TextReplacer.withDefaultEmojiDictionary()

    public static func conversionModelURL(resourcesDirectoryURL: URL) -> URL {
        resourcesDirectoryURL.appendingPathComponent("zenz-v2.5-medium-ane.mlmodelc", isDirectory: true)
    }

    public init(
        kanaKanjiConverter: KanaKanjiConverter,
        applicationDirectoryURL: URL,
        containerURL: URL?,
        context: Context = Context()
    ) {
        self.kanaKanjiConverter = kanaKanjiConverter
        self.applicationDirectoryURL = applicationDirectoryURL
        self.containerURL = containerURL
        self.context = context
    }

    /// テストなどの設定注入のための型。外部には設定を露出させない。
    public struct Context {
        public init() {}
        public init(useZenzai: Bool, resourcesDirectoryURL: URL? = nil) {
            self.useZenzai = useZenzai
            self.resourcesDirectoryURL = resourcesDirectoryURL
        }

        var useZenzai: Bool = true
        var resourcesDirectoryURL: URL?
    }

    public weak var delegate: (any SegmentManagerDelegate)?
    /// Ephemeral input-window reference; never passed to personal learning.
    public var windowReference: WindowReference? {
        didSet { if oldValue?.identity != windowReference?.identity || oldValue?.capturedAt != windowReference?.capturedAt {
            refinedFirstCandidate = nil; typingTypoVerificationCache.removeAll(); clearNextTextCompletion()
        } }
    }
    /// llm-ime: 個人化（場面学習）。nil なら何もしない（従来どおりの変換）
    public weak var personalization: (any SegmentsManagerPersonalization)?
    /// llm-ime: 入力欄の前の文章に書いた漢字の語を、今の読みで読めれば候補に足す（DocumentReadings）
    public var documentReadingsEnabled = true
    private var documentReadings = DocumentReadings()
    private var documentReadingLookupScheduled = false
    private var importedDocumentEntries: [DocumentReadings.Entry] = []
    private var kanaKanjiConverter: KanaKanjiConverter
    private let applicationDirectoryURL: URL
    private let containerURL: URL?
    private let context: Context

    private var composingText: ComposingText = ComposingText()
    private var lastInputStyle: InputStyle = .direct

    private var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }
    private var zenzaiPersonalizationLevel: Config.ZenzaiPersonalizationLevel.Value {
        Config.ZenzaiPersonalizationLevel().value
    }
    private var rawCandidates: ConversionResult?

    private var selectionIndex: Int?
    private var didExperienceSegmentEdition = false
    private var lastOperation: Operation = .other
    private var shouldShowCandidateWindow = false

    private var isShowingAdditionalCandidates = false
    private var additionalCandidates: [CandidatePresentation] = []
    private var showingAdditionalCandidateCount = 0
    private var isFixingAdditionalCandidateTop = false

    private var shouldShowDebugCandidateWindow: Bool = false
    private var debugCandidates: [Candidate] = []

    private var replaceSuggestions: [Candidate] = []
    private var suggestSelectionIndex: Int?
    private var backspaceAdjustedPredictionCandidate: PredictionCandidate?
    /// llm-ime: 打鍵ごとのタイプミス訂正候補（予測ウィンドウに「もしかして」として出す）
    private var typingTypoPredictionCandidate: PredictionCandidate?
    /// llm-ime: zenz による検証結果のキャッシュ（同じ入力・訂正候補を打鍵のたびに検証し直さない）
    private var typingTypoVerificationCache: [String: Float] = [:]
    private var backspaceTypoCorrectionLock: BackspaceTypoCorrectionLock?
    /// llm-ime: 文章の続き予測（入力中の読み・変換結果が変わったら無効）
    private var nextTextCompletion: NextTextCompletion?
    private var presentedNextTextCompletion: NextTextCompletion?

    public struct PredictionCandidate: Sendable, Equatable {
        public var displayText: String
        public var appendText: String
        public var deleteCount: Int = 0

        public init(displayText: String, appendText: String, deleteCount: Int = 0) {
            self.displayText = displayText
            self.appendText = appendText
            self.deleteCount = deleteCount
        }
    }

    struct BackspaceTypoCorrectionLock: Sendable {
        var displayText: String
        var targetReading: String
    }

    public func makeCandidatePresentations(_ candidates: [Candidate]) -> [CandidatePresentation] {
        let additionalPresentations = self.additionalCandidatePresentationsForSelectionIndex
        return candidates.indices.map { index in
            if index < additionalPresentations.count {
                return .init(candidate: candidates[index], displayContext: additionalPresentations[index].displayContext)
            }
            return .init(candidate: candidates[index])
        }
    }

    private lazy var zenzaiPersonalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode? = self.getZenzaiPersonalizationMode()

    private func getZenzaiPersonalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        let alpha = self.zenzaiPersonalizationLevel.alpha
        // オフなので。
        if alpha == 0 {
            return nil
        }
        guard let containerURL else {
            self.appendDebugMessage("❌ Failed to get container URL.")
            return nil
        }

        let base = self.resourcesDirectoryURL.appendingPathComponent("lm", isDirectory: false).path
        let personal = containerURL.appendingPathComponent("Library/Application Support/p13n_v1").path + "/lm"
        // check personal lm existence
        guard [
            FileManager.default.fileExists(atPath: personal + "_c_abc.marisa"),
            FileManager.default.fileExists(atPath: personal + "_r_xbx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_abx.marisa"),
            FileManager.default.fileExists(atPath: personal + "_u_xbc.marisa")
        ].allSatisfy(\.self) else {
            self.appendDebugMessage("❌ Seems like there is missing marisa file for prefix \(personal)")
            return nil
        }

        return .init(baseNgramLanguageModel: base, personalNgramLanguageModel: personal, alpha: alpha)
    }

    private enum Operation: Sendable {
        case insert
        case delete
        case editSegment
        case other
    }

    private enum ContextLength {
        // 変換に渡す左文脈をプロンプト側の上限（40 字）に合わせる。
        static let conversion = 40
        // llm-ime: 続き予測に渡す左文脈。入力欄の文章全体（運べる分）を渡し、モデルに入りきらない分は
        // Gemma4Completer が古い方から削る
        static let completion = ConverterTextContext.leftTransportCharacterLimit
    }

    public func appendDebugMessage(_ string: String) {
        self.debugCandidates.insert(
            Candidate(
                text: string.replacingOccurrences(of: "\n", with: "\\n"),
                value: 0,
                composingCount: .surfaceCount(0),
                lastMid: 0,
                data: []
            ),
            at: 0
        )
        while self.debugCandidates.count > 100 {
            self.debugCandidates.removeLast()
        }
    }

    private func zenzaiMode(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool
    ) -> ConvertRequestOptions.ZenzaiMode {
        if !self.context.useZenzai {
            return .off
        }
        return .on(
            // zenz-v2.5-medium 向けの v2 形式のプロンプトを使う。
            weight: Self.conversionModelURL(resourcesDirectoryURL: self.resourcesDirectoryURL),
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            personalizationMode: self.zenzaiPersonalizationMode,
            versionDependentMode: .v2(
                .init(
                    profile: Config.ZenzaiProfile().value,
                    leftSideContext: leftSideContext,
                    maxLeftSideContextLength: ContextLength.conversion
                )
            )
        )
    }

    private var resourcesDirectoryURL: URL {
        if let resourcesDirectoryURL = self.context.resourcesDirectoryURL {
            return resourcesDirectoryURL
        }
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    private var metadata: ConvertRequestOptions.Metadata {
        if let tag = PackageMetadata.gitTag {
            .init(versionString: "Shizuku (\(tag))")
        } else if let commit = PackageMetadata.gitCommit {
            .init(versionString: "Shizuku (\(commit.prefix(7)))")
        } else {
            .init(versionString: "Shizuku (unknown version)")
        }
    }

    private func options(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool,
        requireJapanesePrediction: ConvertRequestOptions.PredictionMode,
        requireEnglishPrediction: ConvertRequestOptions.PredictionMode
    ) -> ConvertRequestOptions {
        .init(
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            learningType: Config.Learning().value.learningType,
            memoryDirectoryURL: self.memoryDirectoryURL,
            sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.memoryDirectoryURL),
            textReplacer: Self.textReplacer,
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: self.zenzaiMode(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates
            ),
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: self.metadata
        )
    }

    private func hasDebugTypoCorrectionWeights() -> Bool {
        DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: self.downloadedInputN5LMDir)
    }

    public var memoryDirectoryURL: URL {
        self.applicationDirectoryURL
    }

    public var downloadedInputN5LMDir: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            applicationSupportDirectoryURL: self.applicationDirectoryURL.deletingLastPathComponent()
        )
    }

    @MainActor
    public func activate() {
        self.shouldShowCandidateWindow = false
        self.backspaceAdjustedPredictionCandidate = nil
        self.typingTypoPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.zenzaiPersonalizationMode = self.getZenzaiPersonalizationMode()
    }

    @MainActor
    public func reloadUserDictionary() {
        self.kanaKanjiConverter.updateUserDictionaryURL(
            CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.memoryDirectoryURL),
            forceReload: true
        )
    }

    @MainActor
    public func resetLearningData() {
        self.kanaKanjiConverter.resetMemory()
    }

    @MainActor
    public func deactivate(flushLearningData: Bool = true) {
        self.kanaKanjiConverter.stopComposition()
        if flushLearningData {
            self.kanaKanjiConverter.commitUpdateLearningData()
        }
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.composingText.stopComposition()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.typingTypoPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// この入力を打ち切る
    public func stopComposition() {
        self.composingText.stopComposition()
        self.kanaKanjiConverter.stopComposition()
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.typingTypoPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.nextTextCompletion = nil
        self.displayedCompletion = nil
        self.presentedNextTextCompletion = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// 日本語入力自体をやめる
    public func stopJapaneseInput() {
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.typingTypoPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.nextTextCompletion = nil
        self.displayedCompletion = nil
        self.presentedNextTextCompletion = nil
        self.lastInputStyle = .direct
    }

    /// 変換キーを押したタイミングで入力の区切りを示す
    @MainActor
    public func insertCompositionSeparator(inputStyle: InputStyle, skipUpdate: Bool = false) {
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            // すでに末尾がcompositionSeparatorの場合は何もしない
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(string, inputStyle: inputStyle)
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        if self.shouldInsertAsAlphanumeric(pieces: pieces, inputStyle: inputStyle) {
            self.insertAlphanumeric(pieces: pieces)
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
        self.updateTypingTypoCorrection()
    }

    @MainActor
    public func editSegment(count: Int) {
        // 現在選ばれているprefix candidateが存在する場合、まずそれに合わせてカーソルを移動する
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            var afterComposingText = self.composingText
            afterComposingText.prefixComplete(composingCount: candidates[selectionIndex].composingCount)
            let prefixCount = self.composingText.convertTarget.count - afterComposingText.convertTarget.count
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + prefixCount)
        }
        if count > 0 {
            if self.composingText.isAtEndIndex && !self.didExperienceSegmentEdition {
                // 現在のカーソルが右端にある場合、左端の次に移動する
                _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + count)
            } else {
                // それ以外の場合、右に広げる
                _ = self.composingText.moveCursorFromCursorPosition(count: count)
            }
        } else {
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
        }
        if self.composingText.isAtStartIndex {
            // 最初にある場合は一つ右に進める
            _ = self.composingText.moveCursorFromCursorPosition(count: 1)
        }
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1) {
        var previousComposingText = self.composingText.prefixToCursorPosition()
        if !self.composingText.isAtEndIndex {
            // 右端に持っていく
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // 一度segmentの編集状態もリセットにする
            self.didExperienceSegmentEdition = false
            previousComposingText = self.composingText.prefixToCursorPosition()
        }
        self.composingText.deleteBackwardFromCursorPosition(count: count)
        self.lastOperation = .delete
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.typingTypoPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        let currentConvertTarget = self.composingText.convertTarget
        guard count == 1 else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.typingTypoPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
            if self.backspaceAdjustedPredictionCandidate == nil {
                self.backspaceTypoCorrectionLock = nil
            }
            return
        }
        self.backspaceTypoCorrectionLock = self.lmBasedBackspaceTypoCorrectionLock(previousComposingText: previousComposingText)
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
        } else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.typingTypoPredictionCandidate = nil
        }
    }

    @MainActor
    public func forgetMemory() {
        if let selectedCandidate {
            self.kanaKanjiConverter.forgetMemory(selectedCandidate)
            self.appendDebugMessage("\(#function): forget \(selectedCandidate.data.map {$0.word})")
        }
    }

    private var candidates: [Candidate]? {
        guard let rawCandidates = self.rawCandidatesList else {
            return self.isShowingAdditionalCandidates
                ? self.additionalCandidatesForSelectionIndex
                : nil
        }
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    private var rawCandidatesList: [Candidate]? {
        guard let rawCandidates else {
            return nil
        }
        if !self.didExperienceSegmentEdition {
            if rawCandidates.firstClauseResults.contains(where: { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }) {
                // firstClauseCandidateがmainResultsと同じサイズの場合は、何もしない方が良い
                return rawCandidates.mainResults
            } else {
                // 変換範囲がエディットされていない場合
                let seenAsFirstClauseResults = rawCandidates.firstClauseResults.mapSet(transform: \.text)
                return rawCandidates.firstClauseResults + rawCandidates.mainResults.filter {
                    !seenAsFirstClauseResults.contains($0.text)
                }
            }
        } else {
            return rawCandidates.mainResults
        }
    }

    private var candidateOffsetByAdditionalCandidates: Int {
        self.isShowingAdditionalCandidates ? self.showingAdditionalCandidateCount : 0
    }

    private var additionalCandidatesForSelectionIndex: [Candidate] {
        self.additionalCandidatePresentationsForSelectionIndex.map(\.candidate)
    }

    private var additionalCandidatePresentationsForSelectionIndex: [CandidatePresentation] {
        guard self.isShowingAdditionalCandidates else {
            return []
        }
        guard self.candidateOffsetByAdditionalCandidates > 0 else {
            return []
        }
        return Array(self.additionalCandidates.suffix(self.candidateOffsetByAdditionalCandidates))
    }

    public var convertTarget: String {
        self.composingText.convertTarget
    }

    public var isEmpty: Bool {
        self.composingText.isEmpty
    }

    /// llm-ime: 改行より前の行も文脈に含める（改行は空白にする）。カーソルの行だけだと、前の行の言葉を手がかりにできない
    /// （「「all_購入申請_フジ子さん」⏎このチャンネルでもう普通にしんせい」: 最後の行だけなら「新生」、前の行も入れると「申請」）
    public func getCleanLeftSideContext(maxCount: Int) -> String? {
        self.delegate?.getLeftSideContext(maxCount: maxCount).map {
            var text = $0.split(whereSeparator: \.isNewline).joined(separator: " ")
            if text.count > maxCount {
                text = String(text.suffix(maxCount))
            }
            // 前方の空白を削除する
            while text.first?.isWhitespace ?? false {
                text.removeFirst()
            }
            return text
        }
    }

    public func getCleanRightSideContext(maxCount: Int) -> String? {
        self.delegate?.getRightSideContext(maxCount: maxCount).map {
            var first = $0.split(separator: "\n", omittingEmptySubsequences: false).first ?? $0[...]
            // 後方の空白を削除する
            while first.last?.isWhitespace ?? false {
                first = first.dropLast()
            }
            return String(first)
        }
    }

    /// Updates the `self.rawCandidates` based on the current input context.
    ///
    /// This function is responsible for handling candidate conversion,
    /// taking into account partial confirmations and optionally fetching rich candidates.
    /// It also allows an override for the left-side context when necessary.
    ///
    /// - Parameters:
    ///   - requestRichCandidates: A Boolean flag indicating whether to fetch rich candidates (default is `false`). Generating rich candidates takes longer time.
    ///   - forcedLeftSideContext: An optional string that overrides the left-side context (default is `nil`).
    ///
    /// - Note:
    ///   This function is executed on the `@MainActor` to ensure UI consistency.
    @MainActor private func updateRawCandidate(
        requestRichCandidates: Bool = false,
        forcedLeftSideContext: String? = nil,
        forcedRightSideContext: String? = nil
    ) {
        if self.lastOperation != .delete {
            self.backspaceAdjustedPredictionCandidate = nil
            self.typingTypoPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
        }
        self.resetAdditionalCandidates()
        // 不要
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.kanaKanjiConverter.stopComposition()
            return
        }
        /// 日付・時刻変換を事前に入れておく
        let dynamicShortcuts: [DicdataElement] =
            [
                ("M/d", -18, DateTemplateLiteral.CalendarType.western),
                ("yyyy/MM/dd", -18.1, .western),
                ("yyyy-MM-dd", -18.2, .western),
                ("M月d日（E）", -18.3, .western),
                ("yyyy年M月d日", -18.4, .western),
                ("Gyyyy年M月d日", -18.5, .japanese),
                ("E曜日", -18.6, .western)
            ].flatMap { (format, value: PValue, type) in
                [
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-2", deltaUnit: 60 * 60 * 24).export(), ruby: "オトトイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-1", deltaUnit: 60 * 60 * 24).export(), ruby: "キノウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "キョウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "1", deltaUnit: 60 * 60 * 24).export(), ruby: "アシタ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "2", deltaUnit: 60 * 60 * 24).export(), ruby: "アサッテ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
                ]
            } + [
                // 月
                .init(word: DateTemplateLiteral(format: "MM月", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コンゲツ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                // 年
                .init(word: DateTemplateLiteral(format: "yyyy年", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "Gyyyy年", type: .japanese, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                // 時刻
                .init(word: DateTemplateLiteral(format: "HH:mm", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "HH時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                .init(word: DateTemplateLiteral(format: "aK時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.2)
            ]

        self.kanaKanjiConverter.importDynamicUserDictionary(self.prepareDocumentReadings(), shortcuts: dynamicShortcuts)

        let leftSideContext = forcedLeftSideContext ?? self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        let rightSideContext = forcedRightSideContext ?? self.getCleanRightSideContext(maxCount: ContextLength.conversion)
        let conversionOptions = options(
            leftSideContext: leftSideContext,
            rightSideContext: rightSideContext,
            requestRichCandidates: requestRichCandidates,
            requireJapanesePrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
            requireEnglishPrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled
        )
        let result = self.kanaKanjiConverter.requestCandidates(self.composingText, options: conversionOptions)
        self.rawCandidates = result
        self.applyKanaVariantCandidates(leftSideContext: leftSideContext ?? "", options: conversionOptions)
        if var raw = self.rawCandidates, let reference = self.windowReference, !self.didExperienceSegmentEdition {
            let whole: (Candidate) -> Bool = {
                self.composingText.isWholeComposingText(composingCount: $0.composingCount)
                    && $0.data.map(\.ruby).joined() == self.composingText.convertTarget.toKatakana()
            }
            raw.mainResults = reference.promoteGlossary(reference.rerank(raw.mainResults, whole: whole), whole: whole)
            self.rawCandidates = raw
        }
        if var raw = self.rawCandidates {
            raw.mainResults = self.promotingDocumentSurfaces(raw.mainResults, composingText: self.composingText)
            self.rawCandidates = raw
        }
        if let raw = self.rawCandidates, let preferred = self.applyingPersonalPreference(to: raw, composingText: self.composingText) {
            self.rawCandidates = preferred
        }
    }

    // MARK: - 同じ入力欄に書いた表記を先頭に（llm-ime）
    //
    // カーソルより前の文章（Client が送る左文脈）に、読み全体の候補と同じ表記があれば先頭に置く（DocumentGlossary）。
    // 場面学習で覚えた表記はこの後で先頭に置くので、本人が選び直した表記のほうが優先される
    @MainActor private func promotingDocumentSurfaces(_ candidates: [Candidate], composingText text: ComposingText) -> [Candidate] {
        guard !self.didExperienceSegmentEdition,
              let document = self.delegate?.getLeftSideContext(maxCount: ContextLength.completion), !document.isEmpty else {
            return candidates
        }
        let reading = text.convertTarget.toKatakana()
        return DocumentGlossary.promote(candidates, document: document) {
            text.isWholeComposingText(composingCount: $0.composingCount) && $0.data.map(\.ruby).joined() == reading
        }
    }

    // MARK: - 前の文章の漢字の語を候補に足す（llm-ime）
    //
    // 辞書にその読みがない語（「船底」を「せんてい」で）も、前の文章に書いてあり、1 字ずつの読みが辞書で確かめられれば、
    // 動的ユーザー辞書の語として変換に渡す。キーの処理では覚えている読みだけを使い、足りない読みは裏で引く（DocumentReadingLookup）

    /// 足す語のコスト（辞書の一般の語と同じくらい）。まれな読みを使う語ほど低くする
    static func documentWordValue(rank: Int) -> PValue {
        PValue(-11 - 0.1 * Float(min(rank, 40)))
    }

    @MainActor private func prepareDocumentReadings() -> [DicdataElement] {
        if self.documentReadingsEnabled,
           let document = self.delegate?.getLeftSideContext(maxCount: ContextLength.completion), !document.isEmpty {
            self.documentReadings.update(document: document)
            self.documentReadings.match(target: self.composingText.convertTarget.toKatakana())
            self.scheduleDocumentReadingLookup()
        } else {
            self.documentReadings.clear()
        }
        // 同じ読みの変換は前の結果を使い回すので、足す語が変わったときだけ、変換の途中の結果を捨てる
        if self.documentReadings.entries != self.importedDocumentEntries {
            self.importedDocumentEntries = self.documentReadings.entries
            self.kanaKanjiConverter.stopComposition()
        }
        return self.documentReadings.entries.map {
            DicdataElement(word: $0.surface, ruby: $0.ruby, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid,
                           value: Self.documentWordValue(rank: $0.rank))
        }
    }

    /// 足りない読みを 1 つずつ裏で引く。結果は主スレッドで覚え、今の読みの全部の部分で語を探し直す（次の変換から使う）
    @MainActor private func scheduleDocumentReadingLookup() {
        guard self.documentReadingsEnabled, !self.documentReadingLookupScheduled, let part = self.documentReadings.pending.first else {
            return
        }
        self.documentReadingLookupScheduled = true
        // 結果は主スレッドでだけ使う。裏のキューは SegmentsManager に触れない
        let owner = DocumentReadingOwner(manager: self)
        DocumentReadingLookup.shared.lookUp(part) { characters in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = owner.manager else {
                        return
                    }
                    self.documentReadingLookupScheduled = false
                    self.applyDocumentReading(part, characters)
                    if !self.composingText.isEmpty {
                        self.scheduleDocumentReadingLookup()
                    }
                }
            }
        }
    }

    @MainActor private func applyDocumentReading(_ part: String, _ characters: [Character]) {
        self.documentReadings.complete(part, characters)
        if self.documentReadings.match(target: self.composingText.convertTarget.toKatakana(), allSubstrings: true) {
            self.refinedFirstCandidate = nil
        }
    }

    /// 試験・計測用: 足りない読みをすべてその場で引く
    @MainActor func resolveDocumentReadingsNow() {
        while self.resolveDocumentReadingsStep() != nil {}
    }

    /// 試験・計測用: 1 回分を、引く時間（裏のキュー）と覚える時間（主スレッド）に分けて行う
    @MainActor @discardableResult
    func resolveDocumentReadingsStep() -> (part: String, lookupMs: Double, applyMs: Double)? {
        guard let part = self.documentReadings.pending.first else {
            return nil
        }
        let start = Date()
        let characters = DocumentReadingLookup.shared.lookUpNow(part)
        let looked = Date()
        self.applyDocumentReading(part, characters)
        return (part, looked.timeIntervalSince(start) * 1000, Date().timeIntervalSince(looked) * 1000)
    }

    /// 計測用: 辞書を引いた回数・残り・見つけた語
    public var documentReadingStatistics: (lookups: Int, pending: Int, entries: [DocumentReadings.Entry]) {
        (self.documentReadings.lookups, self.documentReadings.pending.count, self.documentReadings.entries)
    }

    // MARK: - 場面学習で覚えた表記を先頭に（llm-ime）
    //
    // 読み全体が、今の場面で本人が選ぶ表記（自動辞書に登録した語）と一致すれば、その表記を第 1 候補にする。
    // 辞書に足しただけでは zenz が文として却下することがあるため、読み全体の一致は確実に先頭へ置く。
    // 第 1 候補を決める 3 か所（入力中の変換、1 回目のスペース、続き予測の土台）すべてで使う

    @MainActor private func applyingPersonalPreference(to result: ConversionResult, composingText text: ComposingText) -> ConversionResult? {
        guard let personalization = self.personalization, !self.didExperienceSegmentEdition else {
            return nil
        }
        let reading = text.convertTarget
        // 打鍵の途中（ローマ字が未確定で残っている）や、シフトで始めた英数字の入力では行わない
        guard !reading.isEmpty, text.isAtEndIndex, let last = reading.last, !(last.isASCII && last.isLetter),
              !self.isInAlphanumericComposition,
              let preferred = personalization.personalPreferredSurface(
                forReading: reading.toKatakana(), leftContext: self.getCleanLeftSideContext(maxCount: 10) ?? ""
              ) else {
            return nil
        }
        var result = result
        if let index = result.mainResults.firstIndex(where: { $0.text == preferred.surface && text.isWholeComposingText(composingCount: $0.composingCount) }) {
            guard index > 0 else {
                return nil
            }
            let candidate = result.mainResults.remove(at: index)
            result.mainResults.insert(candidate, at: 0)
        } else {
            let element = DicdataElement(
                word: preferred.surface, ruby: reading.toKatakana(), lcid: preferred.lcid, rcid: preferred.rcid, mid: preferred.mid,
                value: PersonalLearner.dictionaryValue
            )
            let candidate = Candidate(
                text: preferred.surface,
                value: result.mainResults.first?.value ?? PersonalLearner.dictionaryValue,
                // 区切り（スペースで入る）を含めて入力全体を確定する
                composingCount: .inputCount(text.input.count),
                lastMid: preferred.mid,
                data: [element]
            )
            result.mainResults.insert(candidate, at: 0)
        }
        return result
    }

    // MARK: - ず/づ・じ/ぢ の表記ゆれ（llm-ime）
    //
    // ローマ字で "tuzuki" と打つと「つずき」になり、読みどおりの辞書引きでは「続き」（ツヅキ）が出ない
    // （「ツ好き」などになる）。読みの「ず・じ」を「づ・ぢ」に置き換えた読みも zenz で評価し、
    // 文脈のもとで明らかにもっともらしい（対数確率が margin 以上高い）ときだけ、その変換を候補の先頭に置く。
    // 「かんじ（漢字）」「みず（水）」のような普通の語は置き換えた読みの方が低くなるので変わらない。

    private static let kanaVariantMargin: Float = 1.5
    /// 左文脈＋読み → より良い置き換えの読み（なければ nil）
    private var kanaVariantCache: [String: String?] = [:]

    /// llm-ime: 場面学習。その読みで本人が置き換えを使った・退けた記録で、しきい値を変える（オフなら 1.5 のまま）
    private func kanaVariantMargin(forReading reading: String) -> Float {
        Self.kanaVariantMargin + (self.personalization?.personalKanaVariantMarginAdjustment(forReading: reading.toKatakana()) ?? 0)
    }

    private static func kanaVariantCacheKey(leftSideContext: String, reading: String, margin: Float) -> String {
        leftSideContext + "\u{1F}" + reading + "\u{1F}\(margin)"
    }

    /// 今の入力の読みで、ず/づ の置き換えを候補の先頭に出しているか
    private var isOfferingKanaVariant: Bool {
        let reading = self.composingText.convertTarget
        let key = Self.kanaVariantCacheKey(
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? "",
            reading: reading,
            margin: self.kanaVariantMargin(forReading: reading)
        )
        if let variant = self.kanaVariantCache[key], variant != nil {
            return true
        }
        return false
    }

    /// 「ず→づ」「じ→ぢ」を 1 か所ずつ（と、全部）置き換えた読み。該当が多すぎる読みは対象外
    static func kanaVariants(of reading: String) -> [String] {
        let chars = Array(reading)
        let positions = chars.indices.filter { chars[$0] == "ず" || chars[$0] == "じ" }
        guard !positions.isEmpty, positions.count <= 3 else {
            return []
        }
        func replaced(_ indices: [Int]) -> String {
            var c = chars
            for i in indices {
                c[i] = c[i] == "ず" ? "づ" : "ぢ"
            }
            return String(c)
        }
        var variants = positions.map { replaced([$0]) }
        if positions.count > 1 {
            variants.append(replaced(positions))
        }
        return variants
    }

    @MainActor private func applyKanaVariantCandidates(leftSideContext: String, options: ConvertRequestOptions) {
        guard self.context.useZenzai, !self.didExperienceSegmentEdition, var raw = self.rawCandidates else {
            return
        }
        let reading = self.composingText.convertTarget
        // 打鍵の途中（ローマ字が未確定で残っている）では行わない
        guard self.composingText.isAtEndIndex, let last = reading.last, !(last.isASCII && last.isLetter) else {
            return
        }
        let variants = Self.kanaVariants(of: reading)
        guard !variants.isEmpty else {
            return
        }
        let margin = self.kanaVariantMargin(forReading: reading)
        let cacheKey = Self.kanaVariantCacheKey(leftSideContext: leftSideContext, reading: reading, margin: margin)
        let best: String?
        if let cached = self.kanaVariantCache[cacheKey] {
            best = cached
        } else {
            guard let base = self.kanaKanjiConverter.experimentalReadingLogProbability(
                reading: reading, leftSideContext: leftSideContext, options: options
            ) else {
                return
            }
            var bestScore = base + margin
            var found: String?
            for variant in variants {
                if let score = self.kanaKanjiConverter.experimentalReadingLogProbability(
                    reading: variant, leftSideContext: leftSideContext, options: options
                ), score > bestScore {
                    bestScore = score
                    found = variant
                }
            }
            if self.kanaVariantCache.count > 256 {
                self.kanaVariantCache.removeAll()
            }
            self.kanaVariantCache[cacheKey] = found
            best = found
        }
        guard let variant = best else {
            return
        }
        var variantText = ComposingText()
        variantText.insertAtCursorPosition(variant, inputStyle: .direct)
        let variantResult = self.kanaKanjiConverter.requestCandidates(variantText, options: options)
        // 入力全体を変換した候補だけを、元の入力の文字数（置き換えても同じ）で確定できる形にして先頭に置く
        let replacements = variantResult.mainResults
            .filter { variantText.isWholeComposingText(composingCount: $0.composingCount) }
            .prefix(3)
            .map {
                Candidate(
                    text: $0.text, value: $0.value, composingCount: .surfaceCount(reading.count),
                    lastMid: $0.lastMid, data: $0.data, actions: $0.actions, inputable: $0.inputable
                )
            }
        guard !replacements.isEmpty else {
            return
        }
        let seen = Set(replacements.map(\.text))
        raw.mainResults = replacements + raw.mainResults.filter { !seen.contains($0.text) }
        self.rawCandidates = raw
    }

    @MainActor public func update(requestRichCandidates: Bool) {
        self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        self.shouldShowCandidateWindow = true
    }

    /// llm-ime: 変換（スペース）の第 1 候補を出すための変換。候補ウィンドウの状態は変えない。
    /// 速い変換（requestRichCandidates: false）は、辞書の候補を zenz が 1 か所ずつ直す回数に上限（5 回）があり、
    /// 長い読みでは途中で止まる（「らいがっききゅうがくする」→「らい楽器休学する」）。候補一覧（2 回目のスペース）と同じく
    /// zenz に文を作らせる変換にする（「来学期休学する」）
    @MainActor public func updateForFirstCandidate() {
        self.updateRawCandidate(requestRichCandidates: true)
    }

    /// - note: 画面更新との整合性を保つため、この関数の実行前に左文脈を取得し、これを引数として与える
    @MainActor public func prefixCandidateCommited(
        _ candidate: Candidate,
        leftSideContext: String,
        kind: CommitEvent.Kind = .selection,
        completionSuggestion: String? = nil
    ) {
        if let personalization = self.personalization {
            personalization.segmentsManagerDidCommit(
                self.makeCommitEvent(candidate, kind: kind, leftSideContext: leftSideContext, completionSuggestion: completionSuggestion)
            )
        }
        self.kanaKanjiConverter.setCompletedData(candidate)
        self.kanaKanjiConverter.updateLearningData(candidate)
        self.composingText.prefixComplete(composingCount: candidate.composingCount)

        if !self.composingText.isEmpty {
            // カーソルを右端に移動する
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.didExperienceSegmentEdition = false
            self.shouldShowCandidateWindow = true
            self.selectionIndex = nil
            self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext + candidate.text)
        }
    }

    /// llm-ime: 確定の記録を作る（状態を変える前に呼ぶ）。第 1 候補は、同じ読みの範囲で変換が最初に出した候補
    /// （読み全体なら 1 回目のスペース・ライブ変換で出る候補、文節を選んでいれば一覧の先頭の候補）
    private func makeCommitEvent(
        _ candidate: Candidate,
        kind: CommitEvent.Kind,
        leftSideContext: String,
        completionSuggestion: String?
    ) -> CommitEvent {
        func reading(of candidate: Candidate) -> String {
            candidate.data.map(\.ruby).joined().toKatakana()
        }
        let committedReading = reading(of: candidate)
        var pool: [Candidate] = []
        if let first = self.rawCandidates?.mainResults.first {
            pool.append(first)
        }
        pool.append(contentsOf: self.candidates ?? [])
        let defaultSurface = pool.first { reading(of: $0) == committedReading }?.text
        let rank: Int? = kind == .selection ? self.selectionIndex : nil
        let left = leftSideContext.isEmpty ? (self.delegate?.getLeftSideContext(maxCount: 20) ?? "") : leftSideContext
        let whole = self.composingText.isWholeComposingText(composingCount: candidate.composingCount)
        return CommitEvent(
            kind: kind,
            reading: committedReading,
            surface: candidate.text,
            defaultSurface: defaultSurface,
            rank: rank,
            leftContext: left,
            lcid: candidate.data.first?.lcid,
            rcid: candidate.data.last?.rcid,
            mid: candidate.data.last?.mid,
            completionSuggestion: completionSuggestion,
            typedReading: whole ? self.composingText.convertTarget : nil,
            kanaVariantOffered: whole && self.isOfferingKanaVariant
        )
    }

    public enum CandidateWindow: Sendable {
        case hidden
        case composing([Candidate], selectionIndex: Int?)
        case selecting([Candidate], selectionIndex: Int?)
    }

    public func requestSetCandidateWindowState(visible: Bool) {
        self.shouldShowCandidateWindow = visible
    }

    public func requestDebugWindowMode(enabled: Bool) {
        self.shouldShowDebugCandidateWindow = enabled
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = (self.selectionIndex ?? -1) + 1
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        let selectionIndex = self.selectionIndex ?? 0

        if self.isFixingAdditionalCandidateTop && self.isShowingAdditionalCandidates {
            if self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
                self.showingAdditionalCandidateCount += 1
            }
            self.selectionIndex = 0
            return
        }

        if selectionIndex == 0, !self.isShowingAdditionalCandidates {
            self.showAdditionalCandidatesIfNeeded()
            let additionalCount = self.candidateOffsetByAdditionalCandidates
            if additionalCount > 0 {
                self.isFixingAdditionalCandidateTop = true
                self.selectionIndex = 0
                return
            }
        }
        if selectionIndex == 0, self.isShowingAdditionalCandidates, self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
            self.isFixingAdditionalCandidateTop = true
            self.showingAdditionalCandidateCount += 1
            self.selectionIndex = 0
            return
        }
        self.selectionIndex = max(0, selectionIndex - 1)
    }

    public func requestSelectingRow(_ index: Int) {
        if self.isFixingAdditionalCandidateTop, index != 0 {
            self.isFixingAdditionalCandidateTop = false
        }
        self.selectionIndex = max(0, index)
    }

    public func requestSelectingSuggestionRow(_ row: Int) {
        suggestSelectionIndex = row
    }

    public func stopSuggestionSelection() {
        self.selectionIndex = nil
    }

    public func requestResettingSelection() {
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.resetAdditionalCandidates()
    }

    // MARK: - シフト始まりの英数字入力（llm-ime）
    //
    // 入力の最初の文字をシフト付きの英字（A〜Z）で打ち始めた場合、確定するまで
    // ローマ字かな変換をせずにそのまま入力する（例: 「ChatGPT」が「CはtGPT」にならない）。
    // 状態は持たず、composingText の中身から判定する。確定・全削除で composingText が空になれば
    // 次の入力は通常の日本語入力に戻る。

    private static func rawCharacter(of piece: InputPiece) -> Character? {
        switch piece {
        case .character(let c): c
        case .key(intention: _, input: let c, modifiers: _): c
        case .compositionSeparator: nil
        }
    }

    private static func isUppercaseASCIILetter(_ c: Character) -> Bool {
        c.isASCII && c.isUppercase && c.isLetter
    }

    /// 現在の入力が、シフト付き英字で始まった英数字入力の途中か。
    private var isInAlphanumericComposition: Bool {
        guard let first = self.composingText.input.first,
              first.inputStyle == .direct,
              let c = Self.rawCharacter(of: first.piece),
              Self.isUppercaseASCIILetter(c) else {
            return false
        }
        return self.composingText.input.allSatisfy { $0.inputStyle == .direct }
    }

    private func shouldInsertAsAlphanumeric(pieces: [InputPiece], inputStyle: InputStyle) -> Bool {
        if inputStyle == .direct {
            // 英語モードなど、もともと直接入力の場合は何もしない
            return false
        }
        if self.composingText.input.isEmpty {
            guard let firstPiece = pieces.first, let c = Self.rawCharacter(of: firstPiece) else {
                return false
            }
            return Self.isUppercaseASCIILetter(c)
        }
        return self.isInAlphanumericComposition
    }

    @MainActor
    private func insertAlphanumeric(pieces: [InputPiece]) {
        // 「-」が「ー」になるなど、日本語入力向けの intention を使わず入力した文字そのものを入れる
        let elements: [ComposingText.InputElement] = pieces.compactMap { piece in
            Self.rawCharacter(of: piece).map { .init(piece: .character($0), inputStyle: .direct) }
        }
        self.lastInputStyle = .direct
        self.composingText.insertAtCursorPosition(elements)
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    public var selectedCandidate: Candidate? {
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            return candidates[selectionIndex]
        }
        return nil
    }

    public func getCurrentCandidateWindow(inputState: InputState) -> CandidateWindow {
        switch inputState {
        case .none, .previewing, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            return .hidden
        case .composing:
            // llm-ime: 入力が止まって、変換（スペース）と同じ第 1 候補が求まっていれば、それを見せる（見せた候補と変換の結果を
            // そろえる。打鍵ごとの速い変換の第 1 候補は、長い読みなどで変換の結果と違うことがある）
            if !self.liveConversionEnabled, let refined = self.refinedFirstCandidate,
               refined.convertTarget == self.composingText.convertTarget {
                return .composing([refined.candidate], selectionIndex: 0)
            }
            if !self.liveConversionEnabled, let firstCandidate = self.rawCandidates?.mainResults.first {
                return .composing([firstCandidate], selectionIndex: 0)
            } else {
                return .hidden
            }
        case .selecting:
            if self.shouldShowDebugCandidateWindow {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, debugCandidates.count - 1))
                return .selecting(debugCandidates, selectionIndex: self.selectionIndex)
            } else if self.shouldShowCandidateWindow, let candidates, !candidates.isEmpty {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, candidates.count - 1))
                return .selecting(candidates, selectionIndex: self.selectionIndex)
            } else {
                return .hidden
            }
        }
    }

    public struct MarkedText: Sendable, Equatable, Hashable, Sequence {
        public enum FocusState: Sendable, Equatable, Hashable {
            case focused
            case unfocused
            case none
        }

        public struct Element: Sendable, Equatable, Hashable {
            public var content: String
            public var focus: FocusState
        }
        var text: [Element]

        public var selectionRange: NSRange

        public init(text: [Element], selectionRange: NSRange) {
            self.text = text
            self.selectionRange = selectionRange
        }

        public func makeIterator() -> Array<Element>.Iterator {
            text.makeIterator()
        }

        var isEmpty: Bool {
            self.text.isEmpty
        }
    }

    @MainActor
    public func getModifiedRubyCandidate(inputState: InputState, _ transform: (String) -> String) -> Candidate {
        let (ruby, composingCount): (String, ComposingCount) = switch inputState {
        case .selecting:
            if let selectedRuby = selectedCandidate?.data.map({ $0.ruby }).joined() {
                // `selectedCandidate.data` の全ての `ruby` を連結して返す
                (selectedRuby, .surfaceCount(selectedRuby.count))
            } else {
                // 選択範囲なしの場合はconvertTargetを返す
                (self.convertTarget, .inputCount(self.composingText.input.count))
            }
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            (self.convertTarget, .inputCount(self.composingText.input.count))
        }
        let candidateText = transform(ruby)
        return Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
    }

    @MainActor
    public func getModifiedRomanCandidate(inputState: InputState = .composing, _ transform: (String) -> String) -> Candidate {
        let targetComposingText: ComposingText
        switch inputState {
        case .selecting:
            targetComposingText = self.composingText.prefixToCursorPosition()
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            targetComposingText = self.composingText
        }
        let inputString = targetComposingText.input.map(\.piece).inputString(preferIntention: false)
        let composingCount: ComposingCount = .inputCount(targetComposingText.input.count)
        let candidateText = transform(inputString)
        let candidate = Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: inputString,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
        return candidate
    }

    @MainActor
    private func createAdditionalCandidates() -> [CandidatePresentation] {
        let candidates: [(candidate: Candidate, annotationText: String?)] = [
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0 }, "英数"),
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, "全角英数"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, "半角カナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana() }, "カタカナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toHiragana() }, "ひらがな")
        ]
        return candidates.map {
            .init(
                candidate: $0.candidate,
                displayContext: .init(annotationText: $0.annotationText)
            )
        }
    }

    @MainActor
    private func showAdditionalCandidatesIfNeeded() {
        if self.isShowingAdditionalCandidates {
            return
        }
        guard !self.convertTarget.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        let candidates = self.createAdditionalCandidates()
        guard !candidates.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        self.additionalCandidates = candidates
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
    }

    private func resetAdditionalCandidates() {
        self.isShowingAdditionalCandidates = false
        self.additionalCandidates = []
        self.showingAdditionalCandidateCount = 0
        self.isFixingAdditionalCandidateTop = false
    }

    @MainActor
    public func commitMarkedText(inputState: InputState) -> String {
        let markedText = self.getCurrentMarkedText(inputState: inputState)
        let text = markedText.reduce(into: "") {$0.append(contentsOf: $1.content)}
        if let candidate = self.candidates?.first(where: {$0.text == text}) {
            self.prefixCandidateCommited(candidate, leftSideContext: "", kind: .enter)
        } else if let personalization = self.personalization, !text.isEmpty {
            // llm-ime: 変換せずに確定した（ひらがなのまま、英数字など）
            personalization.segmentsManagerDidCommit(.init(
                kind: .kana, reading: text.toKatakana(), surface: text,
                defaultSurface: self.wholeFirstCandidate?.text, rank: nil,
                leftContext: self.delegate?.getLeftSideContext(maxCount: 20) ?? ""
            ))
        }
        self.stopComposition()
        return text
    }

    // サジェスト候補を設定するメソッド
    public func setReplaceSuggestions(_ candidates: [Candidate]) {
        self.replaceSuggestions = candidates
        self.suggestSelectionIndex = nil
    }

    // サジェスト候補の選択状態をリセット
    public func resetSuggestionSelection() {
        suggestSelectionIndex = nil
    }

    public func requestTypoCorrectionPredictionCandidates() -> [PredictionCandidate] {
        if Config.DebugTypoCorrection().value, let backspaceAdjustedPredictionCandidate {
            return [backspaceAdjustedPredictionCandidate]
        }
        if Config.TypingTypoCorrection().value, let typingTypoPredictionCandidate {
            return [typingTypoPredictionCandidate]
        }
        return []
    }

    // MARK: - 打鍵ごとのタイプミス訂正（llm-ime）
    //
    // 1. 同梱の n-gram（input_n5_lm_v1）でキー配置に基づく打ち間違い（隣接キー・打ち漏れ・余計な 1 打・
    //    二度押し・入れ替え）を探索し、入力どおりの読みより明らかにもっともらしい訂正版を見つける
    // 2. 変換用の zenz で「訂正版」と「入力どおり」の読みのもっともらしさを比べ、訂正版を支持するときだけ採用

    private static let typingTypoNGramMargin: Float = 1.0
    private static let typingTypoZenzMargin: Float = 2.0

    private var bundledInputN5LMPrefix: String? {
        let directory = self.resourcesDirectoryURL.appendingPathComponent("input_n5_lm_v1", isDirectory: true)
        guard DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: directory) else {
            return nil
        }
        return directory.path + "/lm_"
    }

    @MainActor
    private func updateTypingTypoCorrection() {
        self.typingTypoPredictionCandidate = nil
        guard Config.TypingTypoCorrection().value, self.context.useZenzai else {
            return
        }
        // ローマ字入力（かな変換テーブル）のときだけ。英数字入力や直接入力では行わない
        switch self.lastInputStyle {
        case .roman2kana, .mapped:
            break
        case .direct:
            return
        }
        let typedReading = self.composingText.convertTarget
        // 打鍵の途中（ローマ字が未確定で残っている）では判定しない
        guard !typedReading.isEmpty, self.composingText.isAtEndIndex,
              let last = typedReading.last, !(last.isASCII && last.isLetter),
              let lmPrefix = self.bundledInputN5LMPrefix else {
            return
        }
        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? ""
        let options = self.options(
            leftSideContext: leftSideContext,
            rightSideContext: nil,
            requestRichCandidates: false,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled
        )
        let candidates = self.kanaKanjiConverter.experimentalRequestTypoCorrection(
            leftSideContext: leftSideContext,
            composingText: self.composingText,
            options: options,
            inputStyle: self.lastInputStyle,
            config: .init(
                languageModel: .ngram(.init(prefix: lmPrefix, n: 5, d: 0.75)),
                beamSize: 32,
                topK: 64,
                nBest: 5,
                alpha: 6,
                beta: 7,
                gamma: 6,
                delta: 7,
                doublePress: 5
            )
        )
        if let reference = self.windowReference, self.rawCandidates?.mainResults.prefix(5).contains(where: {
            self.composingText.isWholeComposingText(composingCount: $0.composingCount)
                && $0.data.map(\.ruby).joined() == typedReading.toKatakana() && reference.supports($0.text)
        }) == true { return }
        let typedKatakana = typedReading.toKatakana()
        let identity = candidates.first { $0.convertedText.toKatakana() == typedKatakana }
        let alternatives = candidates.filter {
            $0.convertedText.toKatakana() != typedKatakana
                && $0.score - (identity?.score ?? -.infinity) > Self.typingTypoNGramMargin
        }
        let supportedReadings = Set((self.rawCandidates?.mainResults.prefix(5) ?? []).flatMap { $0.data }
            .filter { self.windowReference?.supports($0.word) == true }.map(\.ruby))
        let preferred = self.windowReference.flatMap { reference in
            alternatives.first { reference.supports($0.convertedText)
                || supportedReadings.contains($0.convertedText.toKatakana()) }
        }
        guard let alternative = preferred ?? alternatives.first else { return }
        let cacheKey = leftSideContext + "\u{1F}" + typedKatakana + "\u{1F}" + alternative.convertedText
        // zenz で比べた差（訂正版 − 入力どおり − チャネルコスト）。求められなければ -∞
        let verifiedMargin: Float
        if let cached = self.typingTypoVerificationCache[cacheKey] {
            verifiedMargin = cached
        } else {
            if let altLogProb = self.kanaKanjiConverter.experimentalReadingLogProbability(
                reading: alternative.convertedText,
                leftSideContext: leftSideContext,
                options: options
            ), let typedLogProb = self.kanaKanjiConverter.experimentalReadingLogProbability(
                reading: typedReading,
                leftSideContext: leftSideContext,
                options: options
            ) {
                verifiedMargin = altLogProb - typedLogProb - alternative.channelCost
            } else {
                verifiedMargin = -.infinity
            }
            if self.typingTypoVerificationCache.count > 256 {
                self.typingTypoVerificationCache.removeAll()
            }
            self.typingTypoVerificationCache[cacheKey] = verifiedMargin
        }
        // llm-ime: 場面学習。本人がいつも直す語はしきい値を下げ、出しても使わなかった語は上げる（オフなら従来どおり 2.0）
        let threshold = Self.typingTypoZenzMargin
            + (self.personalization?.personalTypoMarginAdjustment(forTarget: alternative.convertedText.toKatakana()) ?? 0)
        guard verifiedMargin > threshold else {
            return
        }
        let targetReading = alternative.convertedText.toHiragana()
        let converted = self.convertedText(reading: targetReading, leftSideContext: leftSideContext) ?? targetReading
        self.typingTypoPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
            currentConvertTarget: typedReading,
            targetReading: targetReading,
            displayText: "もしかして: " + converted
        )
    }

    // MARK: - 文章の続き予測（llm-ime）
    //
    // 入力中の読みを第 1 候補で変換した文字列と左文脈をつなげ、その続きを Gemma 4（ANE）で予測する。
    // 予測は ConverterServer が非同期に計算し、終わった時点で入力が変わっていなければ予測ウィンドウに出す。
    // Tab で「第 1 候補＋続き」を確定する。

    struct NextTextCompletion: Sendable, Equatable {
        var convertTarget: String
        var base: String
        var suggestion: String
        /// Tab で確定するときに学習に反映する、土台の候補
        var baseCandidate: Candidate
    }

    public struct NextTextCompletionRequest: Sendable, Equatable {
        /// モデルに渡す文脈（左文脈＋現在の第 1 候補）
        public var context: String
        public var convertTarget: String
        public var base: String
    }

    /// 現在の入力の第 1 候補（読み全体を変換したもの）
    private var wholeFirstCandidate: Candidate? {
        guard let first = self.rawCandidates?.mainResults.first,
              self.composingText.isWholeComposingText(composingCount: first.composingCount) else {
            return nil
        }
        return first
    }

    /// 続き予測の土台にする候補。変換（スペース）と同じく、読みの終わりに区切りを入れて変換した第 1 候補。
    /// 入力中の第 1 候補（区切りなし。続きを打つ前提で変換する）は、変換の結果と違うことがある
    /// （「しんせい」: 入力中は「新生」、変換すると「申請」）。続き予測に見せた候補と変換の結果がそろうように、こちらを使う
    @MainActor private func completionBaseCandidate() -> Candidate? {
        let left = self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        // 表記ゆれの置き換え（「つずき」→「続き」）が効いているときは、変換でも同じ候補が先頭になる
        if self.isOfferingKanaVariant {
            return self.wholeFirstCandidate
        }
        var text = self.composingText
        if text.input.last?.piece != .compositionSeparator {
            text.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: self.lastInputStyle)])
        }
        let options = self.options(
            leftSideContext: left,
            rightSideContext: self.getCleanRightSideContext(maxCount: ContextLength.conversion),
            // 変換（スペース）の第 1 候補と同じく、zenz に文を作らせる変換（updateForFirstCandidate を参照）
            requestRichCandidates: true,
            requireJapanesePrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
            requireEnglishPrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled
        )
        var result = self.kanaKanjiConverter.requestCandidates(text, options: options)
        if let reference = self.windowReference, !self.didExperienceSegmentEdition {
            let whole: (Candidate) -> Bool = {
                text.isWholeComposingText(composingCount: $0.composingCount)
                    && $0.data.map(\.ruby).joined() == text.convertTarget.toKatakana()
            }
            result.mainResults = reference.promoteGlossary(reference.rerank(result.mainResults, whole: whole), whole: whole)
        }
        result.mainResults = self.promotingDocumentSurfaces(result.mainResults, composingText: text)
        if let preferred = self.applyingPersonalPreference(to: result, composingText: text) {
            result = preferred
        }
        guard let first = result.mainResults.first, text.isWholeComposingText(composingCount: first.composingCount) else {
            return self.wholeFirstCandidate
        }
        return first
    }

    /// 入力が止まったときに求めた、変換（スペース）と同じ第 1 候補（読みが同じ間だけ使う）
    private var refinedFirstCandidate: (convertTarget: String, candidate: Candidate)?

    /// 変換（スペース）と同じ第 1 候補を求めて覚える。入力中の候補の表示（ライブ変換オフの青い枠）と続き予測の土台に使う。
    /// 変換を 1 回行うので、打鍵ごとではなく、入力が止まっているときに呼ぶ。求められない状態（ローマ字の途中など）なら nil
    @MainActor public func refineFirstCandidate() -> Candidate? {
        let target = self.composingText.convertTarget
        guard !target.isEmpty, self.composingText.isAtEndIndex,
              let last = target.last, !(last.isASCII && last.isLetter) else {
            return nil
        }
        if let refined = self.refinedFirstCandidate, refined.convertTarget == target {
            return refined.candidate
        }
        guard let candidate = self.completionBaseCandidate() else {
            return nil
        }
        self.refinedFirstCandidate = (target, candidate)
        return candidate
    }

    /// 続き予測の土台にする候補（変換と同じ第 1 候補）。要求のときから入力が変わっていれば nil。
    /// 変換を 1 回行うので、打鍵ごとではなく、続き予測ができてから（入力が止まっているときに）呼ぶ
    @MainActor public func completionBase(for request: NextTextCompletionRequest) -> Candidate? {
        guard request.convertTarget == self.composingText.convertTarget else {
            return nil
        }
        return self.refineFirstCandidate()
    }

    /// 現在の入力に対する続き予測の要求。予測できる状態でなければ nil。base を渡すと、それを土台にする
    /// （渡さなければ入力中の第 1 候補。打鍵ごとに呼ぶので、ここでは変換しない）
    @MainActor
    public func makeNextTextCompletionRequest(base: Candidate? = nil) -> NextTextCompletionRequest? {
        guard Config.NextTextCompletion().value else {
            return nil
        }
        switch self.lastInputStyle {
        case .roman2kana, .mapped:
            break
        case .direct:
            return nil
        }
        let target = self.composingText.convertTarget
        // 打鍵の途中（ローマ字が未確定で残っている）では予測しない
        guard !target.isEmpty, self.composingText.isAtEndIndex,
              let last = target.last, !(last.isASCII && last.isLetter),
              let first = base ?? self.wholeFirstCandidate else {
            return nil
        }
        // 最後の行だけでなく、複数行の文章全体を文脈にする
        let left = self.delegate?.getLeftSideContext(maxCount: ContextLength.completion) ?? ""
        return .init(context: left + first.text, convertTarget: target, base: first.text)
    }

    private var displayedCompletion: (target: String, base: String, text: String)?
    public func clearNextTextCompletion() { self.nextTextCompletion = nil; self.displayedCompletion = nil; self.presentedNextTextCompletion = nil }
    public func capturePresentedNextTextCompletion(_ presented: Bool) {
        self.presentedNextTextCompletion = presented ? self.validNextTextCompletion : nil
    }

    /// 予測結果を設定する。計算中に入力が変わっていたら捨てて false を返す。
    public func setNextTextCompletion(_ suggestion: String, base: Candidate, for request: NextTextCompletionRequest) -> Bool {
        guard request.convertTarget == self.composingText.convertTarget, base.text == request.base else {
            return false
        }
        var visible = suggestion
        if let displayed = self.displayedCompletion {
            let previous = displayed.base + displayed.text
            let proposed = request.base + suggestion
            if previous.hasPrefix(request.base), previous.count > request.base.count,
               !CompletionDisplayPolicy.shouldReplace(previous, with: proposed) {
                visible = String(previous.dropFirst(request.base.count))
            }
        }
        self.nextTextCompletion = .init(convertTarget: request.convertTarget, base: request.base, suggestion: visible, baseCandidate: base)
        self.displayedCompletion = (request.convertTarget, request.base, visible)
        return true
    }

    private var validNextTextCompletion: NextTextCompletion? {
        guard Config.NextTextCompletion().value,
              let completion = self.nextTextCompletion,
              completion.convertTarget == self.composingText.convertTarget else {
            return nil
        }
        return completion
    }

    /// 表示中の続き予測（入力中の文字の後ろに続く部分）
    public var nextTextCompletionSuggestion: String? {
        self.validNextTextCompletion?.suggestion
    }

    /// Tab で確定される全文（入力中の読みの第 1 候補＋続き）
    public var nextTextCompletionFullText: String? {
        self.validNextTextCompletion.map { $0.base + $0.suggestion }
    }

    public func requestNextTextCompletionPredictionCandidates() -> [PredictionCandidate] {
        guard let completion = self.validNextTextCompletion else {
            return []
        }
        return [.init(displayText: "⇥ " + completion.base + completion.suggestion, appendText: "")]
    }

    /// 続き予測を確定する（第 1 候補を学習に反映して入力を終える）。確定する文字列を返す。
    @MainActor
    public func acceptNextTextCompletion(leftSideContext: String, displayedOnly: Bool = false) -> String? {
        guard Config.NextTextCompletion().value,
              let completion = displayedOnly ? self.presentedNextTextCompletion : self.validNextTextCompletion,
              completion.convertTarget == self.composingText.convertTarget else {
            return nil
        }
        // 土台の候補は読みの終わりに区切りを入れて変換したもの。変換（スペース）と同じく区切りを入れてから確定する
        // （候補が覚えている入力の長さと、入力中の文字の長さをそろえる）
        self.insertCompositionSeparator(inputStyle: self.lastInputStyle, skipUpdate: true)
        self.prefixCandidateCommited(
            completion.baseCandidate, leftSideContext: leftSideContext, kind: .completion, completionSuggestion: completion.suggestion
        )
        self.stopComposition()
        return completion.base + completion.suggestion
    }

    public static func preferredPredictionCandidates(
        typoCorrectionCandidates: [PredictionCandidate],
        predictionCandidates: [PredictionCandidate]
    ) -> [PredictionCandidate] {
        if !typoCorrectionCandidates.isEmpty {
            return typoCorrectionCandidates
        }
        return predictionCandidates
    }

    public static func shouldPresentTypoCorrectionPredictionCandidate(
        candidateDisplayText: String,
        previousComposingDisplayText: String
    ) -> Bool {
        // 削除前の previousComposingText と同じ表示候補は、訂正候補としては提示しない。
        candidateDisplayText != previousComposingDisplayText
    }

    public func requestPredictionCandidates() -> [PredictionCandidate] {
        guard let candidate = self.firstPredictionCandidate(),
              let prediction = Self.makePredictionCandidate(currentTarget: self.composingText.convertTarget, candidate: candidate) else {
            return []
        }
        return [prediction]
    }

    private func firstPredictionCandidate() -> Candidate? {
        guard Config.DebugPredictiveTyping().value else {
            return nil
        }

        let target = self.composingText.convertTarget
        guard !target.isEmpty else {
            return nil
        }

        guard let rawCandidates else {
            return nil
        }

        return rawCandidates.predictionResults.first {
            Self.makePredictionCandidate(currentTarget: target, candidate: $0) != nil
        }
    }

    static func makePredictionCandidate(
        currentTarget: String,
        candidate: Candidate
    ) -> PredictionCandidate? {
        var matchTarget = currentTarget
        var deleteCount = 0
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            deleteCount = 1
        }
        guard matchTarget.count >= 2 else {
            return nil
        }

        let readingHiragana = candidate.data.map(\.ruby).joined().toHiragana()
        let matchTargetHiragana = matchTarget.toHiragana()
        guard readingHiragana.hasPrefix(matchTargetHiragana) else {
            return nil
        }
        guard matchTargetHiragana.count < readingHiragana.count else {
            return nil
        }

        let appendText = String(readingHiragana.dropFirst(matchTargetHiragana.count))
        guard !appendText.isEmpty else {
            return nil
        }

        return .init(displayText: candidate.text, appendText: appendText, deleteCount: deleteCount)
    }

    @MainActor
    public func acceptPredictionCandidate(allowTypo: Bool = true) {
        if allowTypo, let prediction = self.requestTypoCorrectionPredictionCandidates().first {
            self.acceptTypoCorrectionPredictionCandidate(prediction)
        } else if let candidate = self.firstPredictionCandidate() {
            self.acceptPredictionCandidate(candidate)
        }
    }

    @MainActor
    func acceptPredictionCandidate(_ candidate: Candidate) {
        guard self.kanaKanjiConverter.acceptPredictionCandidate(candidate, composingText: &self.composingText) else {
            return
        }
        self.lastInputStyle = .direct
        self.lastOperation = .insert
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func acceptTypoCorrectionPredictionCandidate(_ prediction: PredictionCandidate) {
        if prediction.deleteCount > 0 {
            self.deleteBackwardFromCursorPosition(count: prediction.deleteCount)
        }
        if !prediction.appendText.isEmpty {
            self.insertAtCursorPosition(prediction.appendText, inputStyle: .direct)
        }
    }

    private func requestTypoCorrectionCandidates(composingText targetComposingText: ComposingText, inputStyle: InputStyle) -> [String] {
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            return []
        }
        guard !targetComposingText.isEmpty else {
            return []
        }

        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? ""
        let typoCandidates = self.kanaKanjiConverter.experimentalRequestTypoCorrection(
            leftSideContext: leftSideContext,
            composingText: targetComposingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            ),
            inputStyle: inputStyle,
            config: .init(
                languageModel: .ngram(.init(prefix: self.downloadedInputN5LMDir.path + "/lm_", n: 5, d: 0.75)),
                beamSize: 16,
                topK: 32,
                nBest: 3
            )
        )

        var seen: Set<String> = []
        return typoCandidates.compactMap { candidate in
            let text = candidate.convertedText.toHiragana()
            guard !text.isEmpty else {
                return nil
            }
            guard seen.insert(text).inserted else {
                return nil
            }
            return text
        }
    }

    private func convertedText(reading: String, leftSideContext: String?) -> String? {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)

        let result = self.kanaKanjiConverter.requestCandidates(
            composingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            )
        )
        return result.mainResults.first?.text
    }

    @MainActor
    private func lmBasedBackspaceTypoCorrectionLock(previousComposingText: ComposingText) -> BackspaceTypoCorrectionLock? {
        let typoCorrectionCandidates = self.requestTypoCorrectionCandidates(
            composingText: previousComposingText,
            inputStyle: self.lastInputStyle
        )
        guard let correctedReading = typoCorrectionCandidates.first else {
            return nil
        }

        let correctedDisplayText = self.convertedText(
            reading: correctedReading,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? correctedReading
        let previousComposingDisplayText = self.convertedText(
            reading: previousComposingText.convertTarget,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? previousComposingText.convertTarget
        guard Self.shouldPresentTypoCorrectionPredictionCandidate(
            candidateDisplayText: correctedDisplayText,
            previousComposingDisplayText: previousComposingDisplayText
        ) else {
            return nil
        }

        return .init(displayText: correctedDisplayText, targetReading: correctedReading)
    }

    static func makeBackspaceTypoCorrectionPredictionCandidate(
        currentConvertTarget: String,
        targetReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        let operation = Self.makeSuffixEditOperation(from: currentConvertTarget, to: targetReading)
            ?? Self.makeSuffixEditOperation(from: currentConvertTarget.toHiragana(), to: targetReading)
        guard let operation else {
            return nil
        }
        return .init(displayText: displayText, appendText: operation.appendText, deleteCount: operation.deleteCount)
    }

    private static func makeSuffixEditOperation(from currentText: String, to targetText: String) -> (appendText: String, deleteCount: Int)? {
        let sharedPrefixLength = zip(currentText, targetText).prefix(while: ==).count
        let deleteCount = currentText.count - sharedPrefixLength
        let appendText = String(targetText.dropFirst(sharedPrefixLength))
        guard deleteCount > 0 || !appendText.isEmpty else {
            return nil
        }
        return (appendText, deleteCount)
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            let text = if self.lastOperation == .delete {
                // 削除のあとは常にひらがなを示す
                self.composingText.convertTarget
            } else if self.liveConversionEnabled,
                      self.composingText.convertTarget.count > 1,
                      let firstCandidate = self.rawCandidates?.mainResults.first {
                // それ以外の場合、ライブ変換が有効なら
                firstCandidate.text
            } else {
                // それ以外
                self.composingText.convertTarget
            }
            return MarkedText(text: [.init(content: text, focus: .none)], selectionRange: .notFound)
        case .previewing:
            if let fullCandidate = self.rawCandidates?.mainResults.first,
               self.composingText.isWholeComposingText(composingCount: fullCandidate.composingCount) {
                return MarkedText(text: [.init(content: fullCandidate.text, focus: .none)], selectionRange: .notFound)
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .selecting:
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                var afterComposingText = self.composingText
                afterComposingText.prefixComplete(composingCount: candidates[self.selectionIndex!].composingCount)
                return MarkedText(
                    text: [
                        .init(content: candidates[self.selectionIndex!].text, focus: .focused),
                        .init(content: afterComposingText.convertTarget, focus: .unfocused)
                    ],
                    selectionRange: NSRange(location: candidates[self.selectionIndex!].text.count, length: 0)
                )
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .replaceSuggestion:
            // サジェスト候補の選択状態を独立して管理
            if let index = suggestSelectionIndex,
               replaceSuggestions.indices.contains(index) {
                return MarkedText(
                    text: [.init(content: replaceSuggestions[index].text, focus: .focused)],
                    selectionRange: NSRange(location: replaceSuggestions[index].text.count, length: 0)
                )
            } else {
                return MarkedText(
                    text: [.init(content: composingText.convertTarget, focus: .none)],
                    selectionRange: .notFound
                )
            }
        case .unicodeInput(let codePoint):
            // Unicode入力モード: "U+" + コードポイントを表示
            let displayText = "U+" + codePoint
            return MarkedText(
                text: [.init(content: displayText, focus: .none)],
                selectionRange: NSRange(location: displayText.count, length: 0)
            )
        }
    }
}

/// llm-ime: 裏のキューの完了を主スレッドの SegmentsManager に渡すための弱い参照（主スレッドでだけ取り出す）
private final class DocumentReadingOwner: @unchecked Sendable {
    weak var manager: SegmentsManager?
    init(manager: SegmentsManager) { self.manager = manager }
}

public protocol SegmentManagerDelegate: AnyObject {
    func getLeftSideContext(maxCount: Int) -> String?
    func getRightSideContext(maxCount: Int) -> String?
}

/// llm-ime: 個人化（場面学習）の差し込み口。ConverterServer のセッションが今の場面に合わせて答える
public protocol SegmentsManagerPersonalization: AnyObject {
    /// 読み全体（カタカナ）について、今の場面で本人が選ぶ表記
    func personalPreferredSurface(forReading reading: String, leftContext: String) -> PersonalLearner.Entry?
    /// 確定した（状態を変える前に呼ぶ）
    func segmentsManagerDidCommit(_ event: SegmentsManager.CommitEvent)
    /// 訂正先の読み（カタカナ）ごとの、「もしかして」を出すしきい値の調整（負なら出やすく、正なら出にくく）
    func personalTypoMarginAdjustment(forTarget reading: String) -> Float
    /// 入力どおりの読み（カタカナ）ごとの、ず/づ の置き換えのしきい値の調整
    func personalKanaVariantMarginAdjustment(forReading reading: String) -> Float
}

public extension SegmentsManagerPersonalization {
    func personalTypoMarginAdjustment(forTarget reading: String) -> Float {
        0
    }

    func personalKanaVariantMarginAdjustment(forReading reading: String) -> Float {
        0
    }
}

public extension SegmentsManager {
    /// llm-ime: 確定の記録（場面学習）
    struct CommitEvent: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// 候補一覧から選んで確定した
            case selection
            /// 表示中の変換（ライブ変換・1 回目のスペース）を Enter などで確定した
            case enter
            /// カタカナ・ひらがな・英数への変換キーで確定した
            case transform
            /// 続き予測を Tab で確定した
            case completion
            /// 変換せずに確定した（ひらがなのまま・英数字）
            case kana
        }

        public var kind: Kind
        /// 確定した範囲の読み（カタカナ）
        public var reading: String
        public var surface: String
        /// 同じ読みの範囲で、変換が最初に出した候補（わからなければ nil）
        public var defaultSurface: String?
        /// 候補一覧で選んだ位置（一覧から選んでいなければ nil）
        public var rank: Int?
        public var leftContext: String
        public var lcid: Int?
        public var rcid: Int?
        public var mid: Int?
        /// 続き予測で足した部分（kind == .completion のとき）
        public var completionSuggestion: String?
        /// 入力全体を確定したときの、入力どおりの読み（ひらがな。ず/づ の置き換えを使ったかを見る）
        public var typedReading: String?
        /// ず/づ の置き換えの変換を候補の先頭に出していたか
        public var kanaVariantOffered = false

        public init(
            kind: Kind, reading: String, surface: String, defaultSurface: String?, rank: Int?, leftContext: String,
            lcid: Int? = nil, rcid: Int? = nil, mid: Int? = nil, completionSuggestion: String? = nil,
            typedReading: String? = nil, kanaVariantOffered: Bool = false
        ) {
            self.kind = kind
            self.reading = reading
            self.surface = surface
            self.defaultSurface = defaultSurface
            self.rank = rank
            self.leftContext = leftContext
            self.lcid = lcid
            self.rcid = rcid
            self.mid = mid
            self.completionSuggestion = completionSuggestion
            self.typedReading = typedReading
            self.kanaVariantOffered = kanaVariantOffered
        }
    }

    /// 入力の打鍵そのもの（ローマ字。打ち直しの記録に使う）
    var rawInputString: String {
        self.composingText.input.map(\.piece).inputString(preferIntention: false)
    }

    /// 候補一覧で今選んでいる位置
    var currentSelectionIndex: Int? {
        self.selectionIndex
    }

    /// 入力がローマ字かな変換（打ち直しの対を記録する対象）か
    var isRomanInput: Bool {
        switch self.lastInputStyle {
        case .roman2kana, .mapped:
            true
        case .direct:
            false
        }
    }
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
