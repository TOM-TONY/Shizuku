//
//  StringConfigItem.swift
//  Shizuku
//
//  Created by miwa on 2024/04/27.
//

import Foundation

protocol StringConfigItem: ConfigItem<String> {}

extension StringConfigItem {
    public var value: String {
        get {
            Config.string(forKey: Self.key) ?? ""
        }
        nonmutating set {
            Config.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    public struct ZenzaiProfile: StringConfigItem {
        public init() {}

        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.ZenzaiProfile"
    }
}

extension Config {
    /// llm-ime: 続き予測に使うモデル（models フォルダの中のフォルダ名）。空なら E4B（省電力なら E2B）
    public struct NextTextCompletionModel: StringConfigItem {
        public init() {}

        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.nextTextCompletion.model"
    }

    /// llm-ime: いい感じ変換・添削・書き直しに使うローカル LLM（models フォルダの中のフォルダ名）。空なら 31B（なければ 12B）
    public struct LocalLLMModel: StringConfigItem {
        public init() {}

        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.localLLM.model"
    }

    /// llm-ime: 設定画面の「モデルのフォルダを開く」（値は使わない。ConverterServer が Finder で開く）
    public static let openModelFolderSettingKey = "dev.tomonari.inputmethod.Shizuku.action.openModelFolder"

    /// llm-ime: 場面学習で記録しないアプリ（bundle ID を改行区切り）。パスワード管理などは既定で除外（PersonalPrivacy）。ターミナル類は記録する
    public struct PersonalLearningExcludedApps: StringConfigItem {
        public init() {}

        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.personalLearning.excludedApps"
    }

    /// llm-ime: 場面学習の設定画面の項目（値は使わない。ConverterServer が扱う）
    public static let personalLearningSummaryKey = "dev.tomonari.inputmethod.Shizuku.personal.summary"
    public static let personalLearningWordKeyPrefix = "dev.tomonari.inputmethod.Shizuku.personal.word."
    public static let personalLearningAppKeyPrefix = "dev.tomonari.inputmethod.Shizuku.personal.app."
    public static let personalLearningDeleteAllKey = "dev.tomonari.inputmethod.Shizuku.action.personal.deleteAll"
    public static let personalLearningExportKey = "dev.tomonari.inputmethod.Shizuku.action.personal.export"
    /// llm-ime: 解析と学習の操作（開始・止める・元に戻す）と表示（状態・最後の結果）
    public static let labStartKey = "dev.tomonari.inputmethod.Shizuku.action.lab.start"
    public static let labUpperBoundKey = "dev.tomonari.inputmethod.Shizuku.action.lab.upperBound"
    public static let labUpperBoundSummaryKey = "dev.tomonari.inputmethod.Shizuku.lab.upperBoundSummary"
    public static let labUpperBoundDataKey = "dev.tomonari.inputmethod.Shizuku.lab.upperBoundData"
    public static let labUpperBoundInspectionKey = "dev.tomonari.inputmethod.Shizuku.lab.upperBoundInspection"
    public static let labStopKey = "dev.tomonari.inputmethod.Shizuku.action.lab.stop"
    public static let labUndoKey = "dev.tomonari.inputmethod.Shizuku.action.lab.undo"
    public static let labStatusKey = "dev.tomonari.inputmethod.Shizuku.lab.status"
    public static let labSummaryKey = "dev.tomonari.inputmethod.Shizuku.lab.summary"
    public static let labReportKey = "dev.tomonari.inputmethod.Shizuku.action.lab.report"
    /// 確かめ用の表示（設定画面には出さない。xpcprobe で読む）: キーを受けてから ShizukuLab が止まるまでの時間
    public static let labDiagnosticsKey = "dev.tomonari.inputmethod.Shizuku.lab.diagnostics"
    /// llm-ime: アクセシビリティの許可の状態（表示だけ）
    public static let personalLearningAccessibilityStatusKey = "dev.tomonari.inputmethod.Shizuku.personal.accessibilityStatus"
    /// llm-ime: このアプリの記録と学習を消す（キーの後ろにバンドル ID）
    public static let personalLearningForgetAppKeyPrefix = "dev.tomonari.inputmethod.Shizuku.action.personal.forgetApp."
    public static let personalLearningResetTuningKey = "dev.tomonari.inputmethod.Shizuku.action.personal.resetTuning"
    public static let personalLearningInputModeKeyPrefix = "dev.tomonari.inputmethod.Shizuku.personal.inputMode."
    public static let personalLearningTuningSummaryKey = "dev.tomonari.inputmethod.Shizuku.personal.tuning"

    /// llm-ime: いい感じ変換（入力中の候補の書き換え）で、どんな文章にするかの指示（ローカル LLM で使う）
    public struct MagicConversionStyle: StringConfigItem {
        public init() {}

        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.magicConversionStyle"
    }
}

extension Config {
    /// OpenAIモデル名
    public struct OpenAiModelName: StringConfigItem {
        public init() {}

        public static let `default`: String = "gpt-4o-mini"
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.OpenAiModelName"
    }

    /// OpenAI API エンドポイント
    public struct OpenAiApiEndpoint: StringConfigItem {
        public init() {}

        public static let `default` = "https://api.openai.com/v1/chat/completions"
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.OpenAiApiEndpoint"

        public var value: String {
            get {
                let stored = Config.string(forKey: Self.key) ?? ""
                return stored.isEmpty ? Self.default : stored
            }
            nonmutating set {
                Config.set(newValue, forKey: Self.key)
            }
        }
    }

    /// プロンプト履歴（JSON形式で保存）
    public struct PromptHistory: StringConfigItem {
        public static let key: String = "dev.tomonari.inputmethod.Shizuku.preference.PromptHistory"
    }
}
