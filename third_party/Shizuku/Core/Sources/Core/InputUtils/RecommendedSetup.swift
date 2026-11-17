import Foundation

/// llm-ime: この Mac のメモリと、入っているモデルに合わせたおすすめの設定。
///
/// 初回起動時（すでに本人の設定があるときを除く）と、設定画面のボタンで同じものを使う。
/// モデルと機能のオン・オフだけを変える。学習・ウィンドウの参照など、プライバシーに関わる設定は変えない。
public enum RecommendedSetup {
    /// 設定の書き込み 1 件（value が nil ならキーを消して既定に戻す）
    public struct Change: @unchecked Sendable {
        public var key: String
        public var value: Any?
    }

    public struct Plan: Equatable, Sendable {
        public var memoryGB: Int
        /// 今の電源の状態によらない、ふだん使う続き予測のモデル（使えるものがなければ nil）
        public var completionModel: String?
        /// いい感じ変換のモデル（ローカル LLM を使わないなら nil）
        public var chatModel: String?
        public var backend: Config.AIBackendPreference.Value

        public var hasAnyModel: Bool {
            self.completionModel != nil || self.chatModel != nil
        }

        /// 設定画面に出す説明
        public var summary: String {
            let completion = self.completionModel.map(ModelCatalog.displayName(forDirectory:)) ?? "オフ（使えるモデルがありません）"
            let chat: String = switch self.backend {
            case .localLLM: self.chatModel.map(ModelCatalog.displayName(forDirectory:)) ?? "オフ"
            case .foundationModels: "Foundation Models"
            case .off, .openAI: "オフ（この Mac で使えるモデルがありません）"
            }
            return "この Mac（メモリ \(self.memoryGB) GB）では: 続きの予測 \(completion)／いい感じ変換 \(chat)"
        }
    }

    public enum FirstRunOutcome: Equatable, Sendable {
        /// おすすめの設定を入れた
        case applied
        /// すでに本人の設定があるので変えなかった
        case keptExisting
        /// モデルがまだ入っていない（入ったあとの起動で入れる）
        case waitingForModels
        /// 判断は済んでいる
        case alreadyDone
    }

    private static let largeChatModel = "gemma4-31b-it-mlx"
    private static let standardChatModel = "gemma4-12b-it-mlx"
    private static let completionModels = ["gemma4-e4b-ane", "gemma4-e2b-ane"]
    private static let manualBackendKey = "hasSetAIBackendManually"
    private static let preferencePrefix = "dev.tomonari.inputmethod.Shizuku.preference."

    /// 初回の判断の状態（設定そのものではないので preference の下に置かない）
    public static let stateKey = "dev.tomonari.inputmethod.Shizuku.recommendedSetup.state"
    private static let doneState = "done"
    private static let waitingState = "waitingForModels"

    /// モデルを待っている間に本人が選んだかを見るキー
    private static var choiceKeys: [String] {
        [
            Config.NextTextCompletion.key, Config.NextTextCompletionIdle.key, Config.NextTextCompletionModel.key,
            Config.LocalLLMModel.key, Config.LocalLLMLargeModel.key, Config.AIBackendPreference.key, Self.manualBackendKey,
        ]
    }

    public static func plan(memoryGB: Int, models: [ModelCatalog.Model], foundationModelsAvailable: Bool) -> Plan {
        let tier = ResourceBudget.resolve(.init(memoryGB: memoryGB))
        let usable = models.filter(\.isUsable)
        let completions = usable.filter { $0.kind == .completion }.map(\.name)
        let chats = usable.filter { $0.kind == .chat }
        let completion = ([tier.completion] + Self.completionModels).first(where: completions.contains) ?? completions.first

        // 同梱の 2 つは資源の段に従う。本人が置いたモデルは、メモリの注意が出ないものだけを候補にする
        var preferred: [String] = []
        if tier.allow31B { preferred.append(Self.largeChatModel) }
        if tier.allow12B { preferred.append(Self.standardChatModel) }
        let names = chats.map(\.name)
        let bundled = [Self.largeChatModel, Self.standardChatModel]
        let chat = preferred.first(where: names.contains)
            ?? chats.first { !bundled.contains($0.name) && $0.warning == nil }?.name
        let backend: Config.AIBackendPreference.Value = chat != nil ? .localLLM : (foundationModelsAvailable ? .foundationModels : .off)
        return Plan(memoryGB: memoryGB, completionModel: completion, chatModel: chat, backend: backend)
    }

    /// おすすめの設定にするための書き込み。
    ///
    /// 続き予測のモデルは「自動」（空）にして、節電中や高温のときに軽いモデルへ下がるようにする。
    /// いい感じ変換は本人が呼んだときに動くものなので、選んだモデルを明示して、電源の状態で断らないようにする。
    public static func changes(for plan: Plan) -> [Change] {
        let predicts = plan.completionModel != nil
        var changes: [Change] = [
            .init(key: Config.NextTextCompletion.key, value: predicts),
            .init(key: Config.NextTextCompletionIdle.key, value: predicts),
            .init(key: Config.NextTextCompletionPowerSaving.key, value: false),
            .init(key: Config.NextTextCompletionModel.key, value: ""),
            .init(key: Config.LocalLLMModel.key, value: plan.chatModel ?? ""),
            .init(key: Config.LocalLLMLargeModel.key, value: nil),
            .init(key: Config.AIBackendPreference.key, value: try? JSONEncoder().encode(plan.backend)),
            .init(key: Self.manualBackendKey, value: true),
            // 入力中の予測と手を止めたときの生成の両方を使うので、「いつ話すか」は詳細の組み合わせになる
            .init(key: AssistanceSettings.timingKey, value: (predicts ? AssistanceSettings.Timing.custom : .called).rawValue),
        ]
        if predicts {
            changes.append(.init(key: AssistanceSettings.contentKey, value: AssistanceSettings.Content.body.rawValue))
        }
        return changes
    }

    /// 初回だけおすすめの設定を入れる。本人の設定が 1 つでもあれば（更新や入れ直しを含む）変えない。
    /// 起動時に書かれる設定と区別するため、設定の移行より前に呼ぶ。
    @discardableResult
    public static func applyOnFirstRun(
        plan: () -> Plan,
        storedKeys: () -> [String],
        read: (String) -> Any?,
        write: (String, Any?) -> Void
    ) -> FirstRunOutcome {
        let state = read(Self.stateKey) as? String
        guard state != Self.doneState else { return .alreadyDone }
        let hasChoice = state == Self.waitingState
            ? Self.choiceKeys.contains { read($0) != nil }
            : read(Self.manualBackendKey) != nil || storedKeys().contains { $0.hasPrefix(Self.preferencePrefix) }
        if hasChoice {
            write(Self.stateKey, Self.doneState)
            return .keptExisting
        }
        let plan = plan()
        guard plan.hasAnyModel else {
            write(Self.stateKey, Self.waitingState)
            return .waitingForModels
        }
        for change in Self.changes(for: plan) {
            write(change.key, change.value)
        }
        write(Self.stateKey, Self.doneState)
        return .applied
    }

    // MARK: - この Mac での実行

    public static func currentPlan() -> Plan {
        Self.plan(
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)),
            models: ModelCatalog.models(),
            foundationModelsAvailable: FoundationModelsClientCompat.checkAvailability().isAvailable
        )
    }

    /// 設定画面のボタン用。以後の初回の判断も済んだものとして扱う
    public static func applyCurrent() -> Plan {
        let plan = Self.currentPlan()
        for change in Self.changes(for: plan) {
            Config.set(change.value, forKey: change.key)
        }
        Config.set(Self.doneState, forKey: Self.stateKey)
        return plan
    }

    /// ConverterServer の起動時に呼ぶ
    @discardableResult
    public static func applyOnFirstRunIfNeeded() -> FirstRunOutcome {
        guard WindowContextTestRuntime.root == nil else { return .alreadyDone }
        return Self.applyOnFirstRun(
            plan: Self.currentPlan,
            storedKeys: { Array(Config.userDefaults.dictionaryRepresentation().keys) },
            read: { Config.object(forKey: $0) },
            write: { Config.set($1, forKey: $0) }
        )
    }
}
