import Foundation
import Core
@preconcurrency import ApplicationServices

extension ConverterServer {
    @MainActor
    static func makeSettingDescriptors(
        capabilities: ConverterSettingClientCapabilities
    ) -> [ConverterSettingDescriptor] {
        func descriptor(
            key: String,
            title: String,
            section: String,
            kind: ConverterSettingKind,
            value: ConverterSettingValue? = nil,
            isEnabled: Bool = true
        ) -> ConverterSettingDescriptor {
            ConverterSettingDescriptor(
                key: key,
                title: title,
                section: section,
                kind: kind,
                value: value,
                isEnabled: isEnabled,
                requiresClientUpdate: requiresClientUpdate(kind: kind, capabilities: capabilities)
            )
        }

        return [
            descriptor(
                key: Config.AIBackendPreference.key,
                title: "いい感じ変換",
                section: "基本",
                kind: .selector(options: [
                    .init(title: "オフ", value: .string(Config.AIBackendPreference.Value.off.rawValue)),
                    .init(title: "Foundation Models", value: .string(Config.AIBackendPreference.Value.foundationModels.rawValue)),
                    .init(title: "ローカル LLM（Gemma 4）", value: .string(Config.AIBackendPreference.Value.localLLM.rawValue))
                ]),
                value: .string(Config.AIBackendPreference().value.rawValue)
            ),
            descriptor(
                key: Config.MagicConversionStyle.key,
                title: "いい感じ変換の指示（ローカル LLM）",
                section: "基本",
                kind: .textField(secure: false),
                value: .string(Config.MagicConversionStyle().value)
            ),
            descriptor(
                key: Config.LiveConversion.key,
                title: "ライブ変換",
                section: "変換設定",
                kind: .toggle,
                value: .bool(Config.LiveConversion().value)
            ),
            descriptor(
                key: Config.NextTextCompletion.key,
                title: "文章の続きを予測（Tab で確定）",
                section: "変換設定",
                kind: .toggle,
                value: .bool(Config.NextTextCompletion().value)
            ),
            descriptor(
                key: Config.NextTextCompletionPowerSaving.key,
                title: "続き予測を省電力モデル（E2B）で動かす",
                section: "変換設定",
                kind: .toggle,
                value: .bool(Config.NextTextCompletionPowerSaving().value)
            ),
            descriptor(
                key: Config.NextTextCompletionIdle.key,
                title: "放置時に本文を生成します",
                section: "変換設定",
                kind: .toggle,
                value: .bool(Config.NextTextCompletionIdle().value),
                isEnabled: Config.NextTextCompletion().value
            ),
            descriptor(
                key: Config.CleanUpAutoOffer.key,
                title: "文末で手を止めたら直前の文の清書を出す（Ctrl+Tab からはいつでも）",
                section: "変換設定",
                kind: .toggle,
                value: .bool(Config.CleanUpAutoOffer().value)
            ),
            Self.modelDescriptor(
                key: Config.NextTextCompletionModel.key,
                title: "続きの予測のモデル",
                section: "変換設定",
                kind: .completion,
                selected: NextTextCompletionEngine.modelDirectoryURL(powerSaving: Config.NextTextCompletionPowerSaving().value).lastPathComponent,
                capabilities: capabilities
            ),
            Self.modelDescriptor(
                key: Config.LocalLLMModel.key,
                title: "いい感じ変換のモデル",
                section: "基本",
                kind: .chat,
                selected: Self.localLLMModelDirectory.lastPathComponent,
                capabilities: capabilities
            ),
            descriptor(
                key: Config.TypeBackSlash.key,
                title: "円記号の代わりにバックスラッシュを入力",
                section: "入力オプション",
                kind: .toggle,
                value: .bool(Config.TypeBackSlash().value)
            ),
            descriptor(
                key: Config.TypeHalfSpace.key,
                title: "スペースは常に半角を入力",
                section: "入力オプション",
                kind: .toggle,
                value: .bool(Config.TypeHalfSpace().value)
            ),
            descriptor(
                key: Config.OptionDirectFullWidthInput.key,
                title: "Optionキーで直接全角英数を入力",
                section: "入力オプション",
                kind: .toggle,
                value: .bool(Config.OptionDirectFullWidthInput().value)
            ),
            descriptor(
                key: Config.PunctuationStyle.key,
                title: "句読点の種類",
                section: "入力オプション",
                kind: .selector(options: [
                    .init(title: "、と。", value: .int(Config.PunctuationStyle.Value.kutenAndToten.rawValue)),
                    .init(title: "、と．", value: .int(Config.PunctuationStyle.Value.periodAndToten.rawValue)),
                    .init(title: "，と。", value: .int(Config.PunctuationStyle.Value.kutenAndComma.rawValue)),
                    .init(title: "，と．", value: .int(Config.PunctuationStyle.Value.periodAndComma.rawValue))
                ]),
                value: .int(Config.PunctuationStyle().value.rawValue)
            ),
            descriptor(
                key: Config.Learning.key,
                title: "履歴学習",
                section: "履歴学習",
                kind: .selector(options: [
                    .init(title: "学習する", value: .string(Config.Learning.Value.inputAndOutput.rawValue)),
                    .init(title: "学習を停止", value: .string(Config.Learning.Value.onlyOutput.rawValue)),
                    .init(title: "学習を無視", value: .string(Config.Learning.Value.nothing.rawValue))
                ]),
                value: .string(Config.Learning().value.rawValue)
            ),
            descriptor(
                key: "dev.tomonari.inputmethod.Shizuku.setting.action.resetLearningData",
                title: "履歴学習データをリセット",
                section: "履歴学習",
                kind: .button(action: "resetLearningData")
            ),
        ] + Self.windowContextDescriptors() + Self.assistanceDescriptors() + Self.personalLearningDescriptors(capabilities: capabilities) + LabController.shared.descriptors(inspection: capabilities.supportedCustomSurfaces.contains("upperBoundInspection")) + [
            descriptor(
                key: Config.InputStyle.key,
                title: "入力方式",
                section: "入力方式",
                kind: .custom(surface: "inputStyle")
            ),
            descriptor(
                key: Config.KeyboardLayout.key,
                title: "キーボード配列",
                section: "キーボード配列",
                kind: .selector(options: [
                    .init(title: "QWERTY", value: .string(Config.KeyboardLayout.Value.qwerty.rawValue)),
                    .init(title: "Australian", value: .string(Config.KeyboardLayout.Value.australian.rawValue)),
                    .init(title: "British", value: .string(Config.KeyboardLayout.Value.british.rawValue)),
                    .init(title: "Colemak", value: .string(Config.KeyboardLayout.Value.colemak.rawValue)),
                    .init(title: "Dvorak", value: .string(Config.KeyboardLayout.Value.dvorak.rawValue)),
                    .init(title: "Dvorak - QWERTY Command", value: .string(Config.KeyboardLayout.Value.dvorakQwertyCommand.rawValue))
                ]),
                value: .string(Config.KeyboardLayout().value.rawValue)
            ),
            descriptor(
                key: Config.ZenzaiProfile.key,
                title: "変換プロフィール",
                section: "変換設定",
                kind: .textField(secure: false),
                value: .string(Config.ZenzaiProfile().value)
            ),
            descriptor(
                key: Config.ZenzaiInferenceLimit.key,
                title: "Zenzaiの推論上限",
                section: "変換設定",
                kind: .number(min: 1, max: 50, step: 1),
                value: .int(Config.ZenzaiInferenceLimit().value)
            ),
            descriptor(
                key: Config.ZenzaiPersonalizationLevel.key,
                title: "パーソナライズ",
                section: "開発者向け設定",
                kind: .selector(options: [
                    .init(title: "オフ", value: .string(Config.ZenzaiPersonalizationLevel.Value.off.rawValue)),
                    .init(title: "弱く", value: .string(Config.ZenzaiPersonalizationLevel.Value.soft.rawValue)),
                    .init(title: "普通", value: .string(Config.ZenzaiPersonalizationLevel.Value.normal.rawValue)),
                    .init(title: "強く", value: .string(Config.ZenzaiPersonalizationLevel.Value.hard.rawValue))
                ]),
                value: .string(Config.ZenzaiPersonalizationLevel().value.rawValue)
            ),
            descriptor(
                key: Config.DebugPredictiveTyping.key,
                title: "開発中の予測入力を有効化",
                section: "開発者向け設定",
                kind: .toggle,
                value: .bool(Config.DebugPredictiveTyping().value)
            ),
            descriptor(
                key: Config.DebugTypoCorrection.key,
                title: "開発中の入力訂正を有効化",
                section: "開発者向け設定",
                kind: .toggle,
                value: .bool(Config.DebugTypoCorrection().value)
            ),
            descriptor(
                key: "dev.tomonari.inputmethod.Shizuku.setting.action.downloadDebugTypoCorrectionWeights",
                title: "入力訂正の重みをダウンロード",
                section: "開発者向け設定",
                kind: .button(action: "downloadDebugTypoCorrectionWeights")
            ),
            descriptor(
                key: Config.UserDictionary.key,
                title: "ユーザー辞書",
                section: "辞書設定",
                kind: .custom(surface: "userDictionary")
            ),
            descriptor(
                key: Config.SystemUserDictionary.key,
                title: "システム辞書",
                section: "辞書設定",
                kind: .custom(surface: "systemUserDictionary")
            ),
            descriptor(
                key: "dev.tomonari.inputmethod.Shizuku.setting.surface.foundationModelsAvailability",
                title: "Foundation Models availability",
                section: "基本",
                kind: .custom(surface: "foundationModelsAvailability")
            ),
            descriptor(
                key: Config.OpenAiModelName.key,
                title: "OpenAIモデル名",
                section: "OpenAI API",
                kind: .textField(secure: false),
                value: .string(Config.OpenAiModelName().value.isEmpty ? Config.OpenAiModelName.default : Config.OpenAiModelName().value)
            ),
            descriptor(
                key: Config.OpenAiApiEndpoint.key,
                title: "OpenAI APIエンドポイント",
                section: "OpenAI API",
                kind: .textField(secure: false),
                value: .string(Config.OpenAiApiEndpoint().value)
            ),
            descriptor(
                key: "dev.tomonari.inputmethod.Shizuku.preference.OpenAiApiKey",
                title: "OpenAI APIキー",
                section: "OpenAI API",
                kind: .textField(secure: true)
            )
        ]
    }

    private static func requiresClientUpdate(
        kind: ConverterSettingKind,
        capabilities: ConverterSettingClientCapabilities
    ) -> Bool {
        guard capabilities.supportedKinds.contains(kind.identifier) else {
            return true
        }
        switch kind {
        case .button(let action):
            return !capabilities.supportedActions.contains(action)
        case .custom(let surface):
            return !capabilities.supportedCustomSurfaces.contains(surface)
        case .toggle, .selector, .textField, .number:
            return false
        }
    }

    /// llm-ime: models フォルダに入っている、使えるモデルの選択肢。値は今実際に使うモデル（選んだものが使えなければ代わりのもの）
    @MainActor
    static func modelDescriptor(
        key: String,
        title: String,
        section: String,
        kind: ModelCatalog.Kind,
        selected: String,
        capabilities: ConverterSettingClientCapabilities
    ) -> ConverterSettingDescriptor {
        let models = ModelCatalog.models(kind: kind)
        let usable = models.filter(\.isUsable)
        let unusable = models.filter { !$0.isUsable }
        if !unusable.isEmpty {
            // 置いたのに出てこない理由をログに残す
            NSLog("llm-ime: unusable models: %@", unusable.map { "\($0.name): \($0.problem ?? "")" }.joined(separator: "; "))
        }
        let kindValue: ConverterSettingKind = .selector(options: usable.map { .init(title: $0.title, value: .string($0.name)) })
        return ConverterSettingDescriptor(
            key: key,
            title: title,
            section: section,
            kind: kindValue,
            value: .string(usable.contains { $0.name == selected } ? selected : ""),
            isEnabled: !usable.isEmpty,
            requiresClientUpdate: requiresClientUpdate(kind: kindValue, capabilities: capabilities)
        )
    }

    @MainActor
    // swiftlint:disable:next cyclomatic_complexity
    static func updateSetting(key: String, value: ConverterSettingValue) throws {
        if key == Config.WindowContextEnabled.key {
            Config.WindowContextEnabled().value = try boolSettingValue(value, key: key)
            WindowContextService.shared.configure(); return
        }
        if key == Config.WindowContextExcludedApps.key {
            guard case .string(let apps) = value else { throw ConverterServerError.invalidSettingValue(key) }
            Config.WindowContextExcludedApps().value = apps
            WindowContextService.shared.configure(); return
        }
        if key == Config.windowContextAXKey || key == Config.windowContextScreenKey {
            guard try boolSettingValue(value, key: key) else { return }
            if key == Config.windowContextAXKey {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            } else { _ = CGRequestScreenCaptureAccess() }
            WindowContextService.shared.configure(); return
        }
        if try Self.updateAssistanceSetting(key: key, value: value) { return }

        // llm-ime: 場面学習の設定・覚えたことの操作、解析と学習
        if try Self.updatePersonalLearningSetting(key: key, value: value) {
            return
        }
        if LabController.shared.update(key: key, value: value) {
            return
        }
        switch key {
        case Config.NextTextCompletionModel.key:
            guard case .string(let name) = value, ModelCatalog.model(named: name, kind: .completion)?.isUsable == true else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.NextTextCompletionModel().value = name
            if Config.NextTextCompletion().value {
                NextTextCompletionEngine.shared.preload()
            }
        case Config.LocalLLMModel.key:
            guard case .string(let name) = value, ModelCatalog.model(named: name, kind: .chat)?.isUsable == true else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.LocalLLMModel().value = name
            LabController.shared.modelChanged()
        case Config.openModelFolderSettingKey:
            // サンドボックスの IME 本体からは開けないので、こちらで Finder に出す
            try? FileManager.default.createDirectory(at: ModelCatalog.directory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [ModelCatalog.directory.path]
            try? process.run()
        case Config.AIBackendPreference.key:
            guard case .string(let rawValue) = value,
                  let backend = Config.AIBackendPreference.Value(rawValue: rawValue) else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.AIBackendPreference().value = backend
        case Config.LiveConversion.key:
            Config.LiveConversion().value = try boolSettingValue(value, key: key)
        case Config.NextTextCompletion.key:
            let enabled = try boolSettingValue(value, key: key)
            Config.NextTextCompletion().value = enabled
            if enabled {
                NextTextCompletionEngine.shared.preload()
            }
        case Config.NextTextCompletionPowerSaving.key:
            Config.NextTextCompletionPowerSaving().value = try boolSettingValue(value, key: key)
            if Config.NextTextCompletion().value {
                NextTextCompletionEngine.shared.preload()
            }
        case Config.NextTextCompletionIdle.key:
            Config.NextTextCompletionIdle().value = try boolSettingValue(value, key: key)
        case Config.CleanUpAutoOffer.key:
            Config.CleanUpAutoOffer().value = try boolSettingValue(value, key: key)
        case Config.TypeBackSlash.key:
            Config.TypeBackSlash().value = try boolSettingValue(value, key: key)
        case Config.TypeHalfSpace.key:
            Config.TypeHalfSpace().value = try boolSettingValue(value, key: key)
        case Config.OptionDirectFullWidthInput.key:
            Config.OptionDirectFullWidthInput().value = try boolSettingValue(value, key: key)
        case Config.PunctuationStyle.key:
            guard case .int(let rawValue) = value,
                  let punctuationStyle = Config.PunctuationStyle.Value(rawValue: rawValue) else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.PunctuationStyle().value = punctuationStyle
        case Config.Learning.key:
            guard case .string(let rawValue) = value,
                  let learning = Config.Learning.Value(rawValue: rawValue) else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.Learning().value = learning
        case Config.KeyboardLayout.key:
            guard case .string(let rawValue) = value,
                  let layout = Config.KeyboardLayout.Value(rawValue: rawValue) else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.KeyboardLayout().value = layout
        case Config.ZenzaiProfile.key:
            guard case .string(let value) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.ZenzaiProfile().value = value
        case Config.MagicConversionStyle.key:
            guard case .string(let value) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.MagicConversionStyle().value = value
            LabController.shared.stop(reason: "書き方の設定が変わったため")
        case Config.ZenzaiInferenceLimit.key:
            guard case .int(let value) = value, (1 ... 50).contains(value) else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.ZenzaiInferenceLimit().value = value
        case Config.ZenzaiPersonalizationLevel.key:
            guard case .string(let rawValue) = value,
                  let level = Config.ZenzaiPersonalizationLevel.Value(rawValue: rawValue) else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.ZenzaiPersonalizationLevel().value = level
        case Config.DebugPredictiveTyping.key:
            Config.DebugPredictiveTyping().value = try boolSettingValue(value, key: key)
        case Config.DebugTypoCorrection.key:
            Config.DebugTypoCorrection().value = try boolSettingValue(value, key: key)
        case Config.OpenAiModelName.key:
            guard case .string(let value) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.OpenAiModelName().value = value
        case Config.OpenAiApiEndpoint.key:
            guard case .string(let value) = value else {
                throw ConverterServerError.invalidSettingValue(key)
            }
            Config.OpenAiApiEndpoint().value = value
        default:
            throw ConverterServerError.unknownSetting(key)
        }
    }

    private static func boolSettingValue(_ value: ConverterSettingValue, key: String) throws -> Bool {
        guard case .bool(let boolValue) = value else {
            throw ConverterServerError.invalidSettingValue(key)
        }
        return boolValue
    }
}

extension ConverterServer {
    @MainActor static func windowContextDescriptors() -> [ConverterSettingDescriptor] {
        let status = WindowContextService.shared.status
        let updated = status.updatedAt.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .standard) } ?? "未取得"
        return [
            .init(key: Config.WindowContextEnabled.key, title: "入力先ウィンドウの会話・資料を参考にする", section: "ウィンドウの参照", kind: .toggle, value: .bool(Config.WindowContextEnabled().value)),
            .init(key: Config.WindowContextExcludedApps.key, title: "読み取らないアプリのbundle ID（改行・カンマ区切り）", section: "ウィンドウの参照", kind: .textField(secure: false), value: .string(Config.WindowContextExcludedApps().value)),
            .init(key: Config.windowContextStatusKey, title: "\(status.state)／アクセシビリティ: \(status.accessibility ? "許可済み" : "未許可")／画面収録: \(status.screenRecording ? "許可済み" : "未許可")／\(status.app ?? "参照なし")／最終更新: \(updated)", section: "ウィンドウの参照", kind: .textField(secure: false), isEnabled: false)
        ]
    }
}
