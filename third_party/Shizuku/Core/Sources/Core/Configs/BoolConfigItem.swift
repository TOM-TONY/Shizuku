import Foundation

protocol BoolConfigItem: ConfigItem<Bool> {
    static var `default`: Bool { get }
}

extension BoolConfigItem {
    static func resolved(_ stored: Any?) -> Bool { stored as? Bool ?? Self.default }
    public var value: Bool {
        get {
            Self.resolved(Config.object(forKey: Self.key))
        }
        nonmutating set {
            Config.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    /// デバッグウィンドウにd/Dで遷移する設定
    public struct DebugWindow: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.debug.enableDebugWindow"
    }
    /// 予測入力のデバッグ機能を有効化する設定
    public struct DebugPredictiveTyping: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.debug.predictiveTyping"
    }
    /// 入力訂正のデバッグ機能を有効化する設定
    public struct DebugTypoCorrection: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.debug.typoCorrection"
    }
    /// llm-ime: 入力中（打鍵ごと）のタイプミス訂正を有効化する設定
    public struct TypingTypoCorrection: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.typingTypoCorrection"
    }
    /// llm-ime: 入力中に文章の続きを予測して表示し、Tab で確定する設定（Gemma 4 on ANE）
    public struct NextTextCompletion: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.nextTextCompletion"
    }
    /// llm-ime: 続き予測に小さいモデル（Gemma 4 E2B）を使って消費電力を抑える設定。オフなら E4B
    public struct NextTextCompletionPowerSaving: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.nextTextCompletion.powerSaving"
    }
    /// llm-ime: 何も入力せずに少し待つと、文章の続きを自動で生成して表示する（Tab で入れる）。続き予測がオンのときだけ働く
    public struct NextTextCompletionIdle: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.nextTextCompletion.idle"
    }
    /// llm-ime: 文末で手を止めたとき、直前の文の清書を自動で 1 件出す（既定オフ。Ctrl+Tab からはいつでも呼べる）
    public struct CleanUpAutoOffer: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.cleanUp.auto"
    }
    /// llm-ime: 続き予測を、入力中の文字の後ろに灰色の文字で重ねて表示する（オフなら予測変換のような別ウィンドウ）
    public struct NextTextCompletionInlineGhost: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.nextTextCompletion.inlineGhost"
    }
    /// llm-ime: 添削・書き直し（選択した文章）でローカル LLM に考えてから答えさせる（遅いが正確になりうる）
    public struct LocalLLMThinking: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.localLLM.thinking"
    }
    /// llm-ime: ローカル LLM に高品質モデル（Gemma 4 31B、約 22GB）を使う（既定）。オフなら軽量の 12B（約 11GB）。
    public struct LocalLLMLargeModel: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.localLLM.largeModel"
    }
    /// llm-ime: 使うほど本人に合わせる（場面学習）。どのアプリのどんな欄で何をどう書いたかを Mac の中だけに記録し、
    /// 変換などを本人に合わせる。オフなら記録も学習した語の反映もしない（従来とまったく同じ動き）
    public struct PersonalLearning: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.personalLearning"
    }
    /// llm-ime: 場面学習の自己調整（続き予測の自信のしきい値・放置の待ち時間・「もしかして」のしきい値を、本人の記録から場面ごとに
    /// 合わせ直す）。場面学習がオンのときだけ働く
    public struct PersonalLearningSelfTuning: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.personalLearning.selfTuning"
    }
    /// llm-ime: 入力欄に合わせて英数・かなを切り替える（アプリごとに、入力欄に入ってすぐ本人がいつも使うモードにする）。
    /// 入力モードを本人の操作なしに変えるので、既定はオフ（本人の判断）。オフのときも観測は数えるが、決して切り替えない
    public struct PersonalInputModeSwitching: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.personalLearning.inputModeSwitching"
    }
    /// llm-ime: 本人がシステム設定でアクセシビリティを許可していれば、入力欄の場所（サイトのホスト名・入力欄の短い符号）で場面を細かく分ける。
    /// 許可がなければ何もしない（許可は求めない）
    public struct PersonalAccessibilityPlaces: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.personalLearning.accessibilityPlaces"
    }
    /// llm-ime: 解析と学習を週 1 回、夜に自動で行う（電源につながっていて、30 分以上操作がなく、熱の状態が通常のとき）
    public struct LabNightly: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.lab.nightly"
    }
    /// llm-ime: 場面学習の記録を一時停止する（覚えたことの反映は続ける）
    public struct PersonalLearningPaused: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.personalLearning.paused"
    }
    /// ライブ変換を有効化する設定
    public struct LiveConversion: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.enableLiveConversion"
    }
    /// 円マークの代わりにバックスラッシュを入力する設定
    public struct TypeBackSlash: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.typeBackSlash"
    }
    /// 「　」の代わりに「 」を入力する設定
    public struct TypeHalfSpace: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.typeHalfSpace"
    }
    /// Optionキー押下時に直接全角英数を入力する設定
    public struct OptionDirectFullWidthInput: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.optionDirectFullWidthInput"
    }
    /// AI変換時にコンテキストを含めるかどうか
    public struct IncludeContextInAITransform: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.includeContextInAITransform"
    }
}
