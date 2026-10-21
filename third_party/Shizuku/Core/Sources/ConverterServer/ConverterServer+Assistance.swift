import Core
import Foundation

extension ConverterServer {
    @MainActor
    static func assistanceDescriptors() -> [ConverterSettingDescriptor] {
        func selector(_ key: String, _ title: String, _ section: String, _ values: [(String, String)], _ selected: String) -> ConverterSettingDescriptor {
            .init(key: key, title: title, section: section,
                  kind: .selector(options: values.map { .init(title: $0.1, value: .string($0.0)) }), value: .string(selected))
        }
        var result = [
            selector(AssistanceSettings.timingKey, "いつ話すか", "助けの設定",
                AssistanceSettings.Timing.allCases.filter { $0 != .custom || AssistanceSettings.timing == .custom }.map { ($0.rawValue, $0.title) }, AssistanceSettings.timing.rawValue),
            selector(AssistanceSettings.contentKey, "何を言ってよいか", "助けの設定",
                AssistanceSettings.Content.allCases.map { ($0.rawValue, $0.title) }, AssistanceSettings.content.rawValue),
            selector(AssistanceSettings.memoryKey, "何を覚えるか", "助けの設定",
                AssistanceSettings.Memory.allCases.filter { $0 != .paused || AssistanceSettings.memory == .paused }.map { ($0.rawValue, $0.title) }, AssistanceSettings.memory.rawValue),
        ]
        let apps = Set(PersonalLearner.shared.appsWithRecords().map(\.app))
            .union(PersonalPrivacy.userExcludedApps()).union(AssistanceSettings.apps.keys)
        for app in apps.sorted() where !PersonalPrivacy.defaultExcludedApps.contains(app) {
            let policy = AssistanceSettings.app(app)
            result.append(selector(AssistanceSettings.appContentPrefix + app, "声", "助けの設定:アプリ",
                [("", "全体に従う")] + AssistanceSettings.Content.allCases.map { ($0.rawValue, $0.title) }, policy.content?.rawValue ?? ""))
            result.append(selector(AssistanceSettings.appTabPrefix + app, "Tab", "助けの設定:アプリ",
                AssistanceSettings.Tab.allCases.map { ($0.rawValue, $0.title) }, policy.tab.rawValue))
        }
        // これまで本体だけで扱っていたキーも同じ値でXPCから確かめられるようにする。
        result.append(.init(key: Config.PersonalInputModeSwitching.key, title: "入力欄に合わせて英数・かなを切り替える",
            section: "場面学習", kind: .toggle, value: .bool(Config.PersonalInputModeSwitching().value)))
        return result
    }

    @MainActor
    static func updateAssistanceSetting(key: String, value: ConverterSettingValue) throws -> Bool {
        guard key.hasPrefix(AssistanceSettings.prefix) else { return false }
        guard case .string(let raw) = value else { throw ConverterServerError.invalidSettingValue(key) }
        switch key {
        case AssistanceSettings.timingKey:
            guard let choice = AssistanceSettings.Timing(rawValue: raw), choice != .custom else { throw ConverterServerError.invalidSettingValue(key) }
            let next = AssistanceSettings.legacy(after: choice, previous: AssistanceSettings.legacy)
            try updateSetting(key: Config.NextTextCompletion.key, value: .bool(next.completion))
            try updateSetting(key: Config.NextTextCompletionIdle.key, value: .bool(next.idle))
        case AssistanceSettings.memoryKey:
            guard let choice = AssistanceSettings.Memory(rawValue: raw), choice != .paused else { throw ConverterServerError.invalidSettingValue(key) }
            let next = AssistanceSettings.legacy(after: choice, previous: AssistanceSettings.legacy)
            try updateSetting(key: Config.PersonalLearning.key, value: .bool(next.learning))
            try updateSetting(key: Config.PersonalLearningPaused.key, value: .bool(next.paused))
        case AssistanceSettings.contentKey:
            guard AssistanceSettings.Content(rawValue: raw) != nil else { throw ConverterServerError.invalidSettingValue(key) }
        case _ where key.hasPrefix(AssistanceSettings.appContentPrefix):
            let app = String(key.dropFirst(AssistanceSettings.appContentPrefix.count))
            guard !app.isEmpty, raw.isEmpty || AssistanceSettings.Content(rawValue: raw) != nil else { throw ConverterServerError.invalidSettingValue(key) }
            var policy = AssistanceSettings.app(app); policy.content = AssistanceSettings.Content(rawValue: raw)
            AssistanceSettings.setApp(policy, id: app); return true
        case _ where key.hasPrefix(AssistanceSettings.appTabPrefix):
            let app = String(key.dropFirst(AssistanceSettings.appTabPrefix.count))
            guard !app.isEmpty, let tab = AssistanceSettings.Tab(rawValue: raw) else { throw ConverterServerError.invalidSettingValue(key) }
            var policy = AssistanceSettings.app(app); policy.tab = tab
            AssistanceSettings.setApp(policy, id: app); return true
        default: throw ConverterServerError.invalidSettingValue(key)
        }
        Config.set(raw, forKey: key)
        return true
    }
}
