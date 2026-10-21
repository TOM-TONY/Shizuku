import Foundation

protocol IntConfigItem: ConfigItem<Int> {
    static var `default`: Int { get }
}

extension IntConfigItem {
    public var value: Int {
        get {
            if let value = Config.object(forKey: Self.key) {
                value as? Int ?? Self.default
            } else {
                Self.default
            }
        }
        nonmutating set {
            Config.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    public struct ZenzaiInferenceLimit: IntConfigItem {
        public init() {}
        static let `default` = 5
        public static let key = "dev.tomonari.inputmethod.Shizuku.preference.zenzaiInferenceLimit"
    }
    /// llm-ime: 場面学習の記録を残す日数（0 なら期限なし）
    public struct PersonalLearningRetentionDays: IntConfigItem {
        public init() {}
        static let `default` = 180
        public static let key = "dev.tomonari.inputmethod.Shizuku.preference.personalLearning.retentionDays"
    }
}
