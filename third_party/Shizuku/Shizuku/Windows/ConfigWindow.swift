import Cocoa
import Core
import SwiftUI

struct ConfigWindow: View {
    @ConfigState private var liveConversion = Config.LiveConversion()
    @ConfigState private var typingTypoCorrection = Config.TypingTypoCorrection()
    @ConfigState private var nextTextCompletion = Config.NextTextCompletion()
    @ConfigState private var nextTextCompletionInlineGhost = Config.NextTextCompletionInlineGhost()
    @ConfigState private var nextTextCompletionIdle = Config.NextTextCompletionIdle()
    @ConfigState private var nextPromptSuggestion = Config.NextPromptSuggestion()
    @ConfigState private var inputStyle = Config.InputStyle()
    @ConfigState private var zenzaiProfile = Config.ZenzaiProfile()
    @ConfigState private var zenzaiPersonalizationLevel = Config.ZenzaiPersonalizationLevel()
    @ConfigState private var openAiApiKey = Config.OpenAiApiKey()
    @ConfigState private var openAiModelName = Config.OpenAiModelName()
    @ConfigState private var openAiApiEndpoint = Config.OpenAiApiEndpoint()
    @ConfigState private var learning = Config.Learning()
    @ConfigState private var inferenceLimit = Config.ZenzaiInferenceLimit()
    @ConfigState private var debugWindow = Config.DebugWindow()
    @ConfigState private var debugPredictiveTyping = Config.DebugPredictiveTyping()
    @ConfigState private var debugTypoCorrection = Config.DebugTypoCorrection()
    @ConfigState private var userDictionary = Config.UserDictionary()
    @ConfigState private var systemUserDictionary = Config.SystemUserDictionary()
    @ConfigState private var aiBackend = Config.AIBackendPreference()
    @ConfigState private var magicConversionStyle = Config.MagicConversionStyle()
    @ConfigState private var localLLMThinking = Config.LocalLLMThinking()
    @ConfigState private var personalLearning = Config.PersonalLearning()
    @ConfigState private var personalLearningPaused = Config.PersonalLearningPaused()
    @ConfigState private var personalLearningSelfTuning = Config.PersonalLearningSelfTuning()
    @ConfigState private var personalInputModeSwitching = Config.PersonalInputModeSwitching()

    @State private var converterServerClient = ConverterServerClient()
    @State private var converterSettingDescriptors: [String: ConverterSettingDescriptor] = [:]
    /// Server が返した順（場面学習の覚えた語・アプリの一覧の並びに使う）
    @State private var converterSettingOrder: [String] = []
    @State private var showingPersonalDeleteConfirmation = false
    /// llm-ime: 記録を消すアプリ（確かめるダイアログに出す）
    @State private var personalForgetTarget: ConverterSettingDescriptor?
    @State private var converterSettingsLoading = false
    @State private var converterSettingsErrorMessage: String?
    @State private var selectedTab: Tab = .basic
    @State private var zenzaiProfileHelpPopover = false
    @State private var zenzaiInferenceLimitHelpPopover = false
    @State private var openAiApiKeyPopover = false
    @State private var connectionTestInProgress = false
    @State private var showingRomajiTableEditor = false
    @State private var connectionTestResult: String?
    @State private var systemUserDictionaryUpdateMessage: SystemUserDictionaryUpdateMessage?
    @State private var showingLearningResetConfirmation = false
    @State private var learningResetMessage: LearningResetMessage?
    @State private var foundationModelsAvailability: FoundationModelsAvailability?
    @State private var availabilityCheckDone = false
    @State private var debugTypoCorrectionState: DebugTypoCorrectionState = .notDownloaded
    @State private var debugTypoCorrectionDownloadInProgress = false
    @State private var debugTypoCorrectionErrorMessage: String?
    @State private var converterProcessRestartInProgress = false
    @State private var converterProcessRestartMessage: String?

    private enum Tab: String, CaseIterable, Hashable {
        case basic = "基本"
        case customize = "カスタマイズ"
        case advanced = "詳細設定"

        var icon: String {
            switch self {
            case .basic: return "star"
            case .customize: return "slider.horizontal.3"
            case .advanced: return "gearshape.2"
            }
        }
    }

    private enum LearningResetMessage {
        case success
        case error(String)
    }

    private enum SystemUserDictionaryUpdateMessage {
        case error(any Error)
        case successfulUpdate
    }

    private var applicationSupportDirectoryURL: URL {
        AppGroup.applicationSupportDirectoryURL()
    }

    private var debugTypoCorrectionModelDirectoryURL: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            applicationSupportDirectoryURL: self.applicationSupportDirectoryURL
        )
    }

    private var debugTypoCorrectionStatusText: String {
        if self.debugTypoCorrectionDownloadInProgress {
            return "ダウンロード中..."
        }
        switch self.debugTypoCorrectionState {
        case .downloaded:
            return "重み: ダウンロード済み"
        case .failed:
            return "重み: ダウンロード失敗"
        case .notDownloaded:
            return "重み: ダウンロード未実施"
        }
    }

    private var converterSettingClientCapabilities: ConverterSettingClientCapabilities {
        ConverterSettingClientCapabilities(
            supportedKinds: [.toggle, .selector, .textField, .number],
            supportedActions: [],
            supportedCustomSurfaces: []
        )
    }

    @MainActor
    private func loadConverterSettingsIfNeeded() {
        guard self.converterSettingDescriptors.isEmpty, !self.converterSettingsLoading else {
            return
        }
        self.reloadConverterSettings()
    }

    @MainActor
    private func reloadConverterSettings() {
        self.converterSettingsLoading = true
        self.converterSettingsErrorMessage = nil
        self.converterServerClient.listSettings(capabilities: self.converterSettingClientCapabilities) { settings in
            DispatchQueue.main.async {
                guard let settings else {
                    self.converterSettingsLoading = false
                    self.converterSettingsErrorMessage = "Converter Processから設定を取得できませんでした"
                    return
                }
                self.converterSettingDescriptors = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0) })
                self.converterSettingOrder = settings.map(\.key)
                self.converterSettingsLoading = false
            }
        }
    }

    @MainActor
    private func updateConverterSetting(key: String, value: ConverterSettingValue) {
        self.converterServerClient.updateSetting(key: key, value: value) { success in
            DispatchQueue.main.async {
                guard success else {
                    self.converterSettingsErrorMessage = "Converter Processに設定を保存できませんでした"
                    self.reloadConverterSettings()
                    return
                }
                if key.hasPrefix(AssistanceSettings.prefix) || key.contains("windowContext") {
                    self.reloadConverterSettings()
                    return
                }
                if var descriptor = self.converterSettingDescriptors[key] {
                    descriptor.value = value
                    self.converterSettingDescriptors[key] = descriptor
                }
            }
        }
    }

    private func converterSettingValueID(_ value: ConverterSettingValue?) -> String {
        switch value {
        case .bool(let value):
            "bool:\(value)"
        case .string(let value):
            "string:\(value)"
        case .int(let value):
            "int:\(value)"
        case .double(let value):
            "double:\(value)"
        case .none:
            ""
        }
    }

    @MainActor
    private func refreshDebugTypoCorrectionState() async {
        let modelDirectoryURL = self.debugTypoCorrectionModelDirectoryURL
        let state = await Task.detached(priority: .utility) { () -> DebugTypoCorrectionState in
            DebugTypoCorrectionWeights.state(modelDirectoryURL: modelDirectoryURL)
        }.value
        self.debugTypoCorrectionState = state
        if state != .failed {
            self.debugTypoCorrectionErrorMessage = nil
        }
    }

    @MainActor
    private func downloadDebugTypoCorrectionWeights() {
        guard !self.debugTypoCorrectionDownloadInProgress else {
            return
        }
        self.debugTypoCorrectionDownloadInProgress = true
        self.debugTypoCorrectionErrorMessage = nil

        let modelDirectoryURL = self.debugTypoCorrectionModelDirectoryURL
        Task {
            do {
                try await DebugTypoCorrectionWeights.downloadWeights(modelDirectoryURL: modelDirectoryURL)
                let state = await Task.detached(priority: .utility) {
                    DebugTypoCorrectionWeights.state(modelDirectoryURL: modelDirectoryURL)
                }.value
                await MainActor.run {
                    self.debugTypoCorrectionState = state
                    self.debugTypoCorrectionErrorMessage = state == .failed ? "ダウンロード後の整合性チェックに失敗しました" : nil
                    self.debugTypoCorrectionDownloadInProgress = false
                }
            } catch {
                await MainActor.run {
                    self.debugTypoCorrectionState = .failed
                    self.debugTypoCorrectionErrorMessage = error.localizedDescription
                    self.debugTypoCorrectionDownloadInProgress = false
                }
            }
        }
    }

    @MainActor
    private func restartConverterProcess() {
        guard !self.converterProcessRestartInProgress else {
            return
        }
        self.converterProcessRestartInProgress = true
        self.converterProcessRestartMessage = nil
        self.converterServerClient.restartServer { success in
            DispatchQueue.main.async {
                self.converterProcessRestartMessage = success ? "再起動しました" : "Converter Processに再起動を依頼できませんでした"
                self.converterProcessRestartInProgress = false
            }
        }
    }

    private func openDataDirectoryInFinder() {
        do {
            try FileManager.default.createDirectory(
                at: self.applicationSupportDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([self.applicationSupportDirectoryURL])
        } catch {
            // no-op
        }
    }

    private func exportUserDictionary() {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.exportUserDictionaryAndReloadConverter()
        }
    }

    private func getErrorMessage(for error: OpenAIError) -> String {
        switch error {
        case .invalidURL:
            return "エラー: 無効なURL形式です"
        case .noServerResponse:
            return "エラー: サーバーから応答がありません"
        case .invalidResponseStatus(let code, let body):
            return getHTTPErrorMessage(code: code, body: body)
        case .parseError(let message):
            return "エラー: レスポンス解析失敗 - \(message)"
        case .invalidResponseStructure:
            return "エラー: 予期しないレスポンス形式"
        }
    }

    private func getHTTPErrorMessage(code: Int, body: String) -> String {
        switch code {
        case 401:
            return "エラー: APIキーが無効です"
        case 403:
            return "エラー: アクセスが拒否されました"
        case 404:
            return "エラー: エンドポイントが見つかりません"
        case 429:
            return "エラー: レート制限に達しました"
        case 500...599:
            return "エラー: サーバーエラー (コード: \(code))"
        default:
            return "エラー: HTTPステータス \(code)\n詳細: \(body.prefix(100))..."
        }
    }

    func testConnection() async {
        connectionTestInProgress = true
        connectionTestResult = nil

        do {
            let testRequest = OpenAIRequest(
                prompt: "テスト",
                target: "",
                modelName: openAiModelName.value.isEmpty ? Config.OpenAiModelName.default : openAiModelName.value
            )
            _ = try await OpenAIClient.sendRequest(
                testRequest,
                apiKey: openAiApiKey.value,
                apiEndpoint: openAiApiEndpoint.value
            )

            connectionTestResult = "接続成功"
        } catch let error as OpenAIError {
            connectionTestResult = getErrorMessage(for: error)
        } catch {
            connectionTestResult = "エラー: \(error.localizedDescription)"
        }

        connectionTestInProgress = false
    }

    @MainActor
    private func resetLearningData() {
        self.converterServerClient.resetLearningData { success in
            self.learningResetMessage = success
                ? .success
                : .error("学習データのリセットに失敗しました")
        }

        // 10秒後にメッセージを消す
        Task {
            try? await Task.sleep(for: .seconds(10))
            if case .success = learningResetMessage {
                learningResetMessage = nil
            }
        }
    }

    @ViewBuilder
    private func helpButton(helpContent: LocalizedStringKey, isPresented: Binding<Bool>) -> some View {
        if #available(macOS 14, *) {
            Button("ヘルプ", systemImage: "questionmark") {
                isPresented.wrappedValue = true
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .popover(isPresented: isPresented) {
                Text(helpContent).padding()
            }
        }
    }

    @ViewBuilder
    private func converterSettingSection(title: String, systemImage: String, keys: [String]) -> some View {
        Section {
            if self.converterSettingsLoading && self.converterSettingDescriptors.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
            if let converterSettingsErrorMessage {
                Text(converterSettingsErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(keys, id: \.self) { key in
                if let setting = self.converterSettingDescriptors[key] {
                    converterSettingRow(setting)
                }
            }
        } header: {
            Label(title, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private func converterSettingRow(_ setting: ConverterSettingDescriptor) -> some View {
        let isDisabled = !setting.isEnabled || setting.requiresClientUpdate
        switch setting.kind {
        case .toggle:
            converterToggleSettingRow(setting, isDisabled: isDisabled)
        case .selector(let options):
            converterSelectorSettingRow(setting, options: options, isDisabled: isDisabled)
        case .textField(let secure):
            converterTextSettingRow(setting, secure: secure, isDisabled: isDisabled)
        case .number(let min, let max, let step):
            converterNumberSettingRow(setting, min: min, max: max, step: step, isDisabled: isDisabled)
        case .button, .custom:
            EmptyView()
        }
    }

    private func converterToggleSettingRow(_ setting: ConverterSettingDescriptor, isDisabled: Bool) -> some View {
        Toggle(
            setting.title,
            isOn: Binding(
                get: {
                    if case .bool(let value) = self.converterSettingDescriptors[setting.key]?.value {
                        return value
                    }
                    return false
                },
                set: {
                    self.updateConverterSetting(key: setting.key, value: .bool($0))
                }
            )
        )
        .disabled(isDisabled)
    }

    private func converterSelectorSettingRow(
        _ setting: ConverterSettingDescriptor,
        options: [ConverterSettingOption],
        isDisabled: Bool
    ) -> some View {
        Picker(
            setting.title,
            selection: Binding(
                get: {
                    self.converterSettingValueID(self.converterSettingDescriptors[setting.key]?.value)
                },
                set: { selectedID in
                    guard let option = options.first(where: { self.converterSettingValueID($0.value) == selectedID }) else {
                        return
                    }
                    self.updateConverterSetting(key: setting.key, value: option.value)
                }
            )
        ) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.title)
                    .tag(self.converterSettingValueID(option.value))
            }
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private func converterTextSettingRow(
        _ setting: ConverterSettingDescriptor,
        secure: Bool,
        isDisabled: Bool
    ) -> some View {
        let binding = Binding(
            get: {
                if case .string(let value) = self.converterSettingDescriptors[setting.key]?.value {
                    return value
                }
                return ""
            },
            set: {
                self.updateConverterSetting(key: setting.key, value: .string($0))
            }
        )
        if secure {
            SecureField(setting.title, text: binding)
                .disabled(isDisabled)
        } else {
            TextField(setting.title, text: binding)
                .disabled(isDisabled)
        }
    }

    private func converterNumberSettingRow(
        _ setting: ConverterSettingDescriptor,
        min: Double?,
        max: Double?,
        step: Double?,
        isDisabled: Bool
    ) -> some View {
        let range = (min ?? 0) ... (max ?? 100)
        return LabeledContent(setting.title) {
            Stepper(
                value: Binding(
                    get: {
                        if case .int(let value) = self.converterSettingDescriptors[setting.key]?.value {
                            return Double(value)
                        }
                        if case .double(let value) = self.converterSettingDescriptors[setting.key]?.value {
                            return value
                        }
                        return min ?? 0
                    },
                    set: { value in
                        if case .int = setting.value {
                            self.updateConverterSetting(key: setting.key, value: .int(Int(value)))
                        } else {
                            self.updateConverterSetting(key: setting.key, value: .double(value))
                        }
                    }
                ),
                in: range,
                step: step ?? 1
            ) {
                Text(self.converterSettingDisplayValue(for: setting.key))
            }
            .disabled(isDisabled)
        }
    }

    private func converterSettingDisplayValue(for key: String) -> String {
        self.converterSettingValueID(self.converterSettingDescriptors[key]?.value).split(separator: ":").last.map(String.init) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // カスタムタブバー
            HStack(spacing: 4) {
                ForEach([Tab.basic, Tab.customize, Tab.advanced], id: \.self) { tab in
                    Button(
                        action: {
                            selectedTab = tab
                        },
                        label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(selectedTab == tab ? Color(nsColor: .controlAccentColor) : Color(nsColor: .secondaryLabelColor))
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: selectedTab == tab ? .medium : .regular))
                                    .foregroundColor(selectedTab == tab ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedTab == tab ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        selectedTab == tab ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                                        lineWidth: 0.5
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                    )
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.3))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // コンテンツエリア（選択されたタブのみ表示）
            Group {
                if selectedTab == .basic {
                    basicTabView
                } else if selectedTab == .customize {
                    customizeTabView
                } else {
                    advancedTabView
                }
            }
        }
        .frame(width: 600, height: 500)
        .sheet(isPresented: $showingRomajiTableEditor) {
            RomajiTableEditorWindow(base: CustomInputTableStore.loadTable()) { exported in
                do {
                    _ = try CustomInputTableStore.save(exported: exported)
                    CustomInputTableStore.registerIfExists()
                } catch {
                    print("Failed to save custom input table: \(error)")
                }
            }
        }
        .task {
            await MainActor.run {
                self.loadConverterSettingsIfNeeded()
            }
        }
    }

    /// llm-ime: モデルの選択（一覧は ConverterServer が models フォルダを調べて返す。IME 本体からはフォルダを読めないため）
    @ViewBuilder
    private func modelPicker(key: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let setting = self.converterSettingDescriptors[key] {
                if case .selector(let options) = setting.kind, options.isEmpty {
                    Text("\(setting.title): 使えるモデルが見つかりません")
                        .foregroundColor(.red)
                } else {
                    self.converterSettingRow(setting)
                }
            } else if self.converterSettingsLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("モデルのフォルダを開く") {
                    self.updateConverterSetting(key: Config.openModelFolderSettingKey, value: .bool(true))
                }
                Button("一覧を更新") {
                    self.reloadConverterSettings()
                }
            }
            .controlSize(.small)
        }
    }

    /// llm-ime: 項目名と、その下の小さな説明を持つスイッチ
    private func describedToggle(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let source = PackageMetadata.gitTag ?? PackageMetadata.gitCommit.map { String($0.prefix(7)) }
        return [version, source.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: - 基本タブ
    @ViewBuilder
    private var basicTabView: some View {
        Form {
            self.assistanceAxesSection
            self.windowContextSection
            Section {
                VStack(alignment: .leading) {
                    Picker("いい感じ変換", selection: $aiBackend) {
                        Text("オフ").tag(Config.AIBackendPreference.Value.off)

                        if let availability = foundationModelsAvailability, availability.isAvailable {
                            Text("Foundation Models").tag(Config.AIBackendPreference.Value.foundationModels)
                        }

                        // llm-ime: 外部 API（OpenAI 互換）は完全ローカル版では選択不可
                        Text("ローカル LLM（Gemma 4・GPU）").tag(Config.AIBackendPreference.Value.localLLM)
                    }
                    .onAppear {
                        if !availabilityCheckDone {
                            foundationModelsAvailability = FoundationModelsClientCompat.checkAvailability()
                            availabilityCheckDone = true

                            let hasSetAIBackend = Config.object(forKey: "hasSetAIBackendManually") as? Bool ?? false
                            if !hasSetAIBackend,
                               aiBackend.value == .off,
                               let availability = foundationModelsAvailability,
                               availability.isAvailable {
                                aiBackend.value = .foundationModels
                                Config.set(true, forKey: "hasSetAIBackendManually")
                            }

                            if aiBackend.value == .foundationModels,
                               let availability = foundationModelsAvailability,
                               !availability.isAvailable {
                                aiBackend.value = .off
                            }
                        }
                    }
                    .onChange(of: aiBackend.value) { _ in
                        Config.set(true, forKey: "hasSetAIBackendManually")
                    }
                }

                if aiBackend.value == .localLLM {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("いい感じ変換の文体（入力中に いい感じ変換 をしたときの指示）")
                        TextEditor(text: $magicConversionStyle)
                            .font(.body)
                            .frame(minHeight: 54, maxHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        Text("例: 丁寧なビジネスメールの文体にする ／ 友達に送るカジュアルな文体で、絵文字も少し使う。空欄なら言い回しや丁寧さの異なる候補を出します。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("モデルは使うときだけ読み込み、5 分使わなければ解放します。選択した文章の添削・書き直し（Ctrl+S）にも使います。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        self.modelPicker(
                            key: Config.LocalLLMModel.key,
                            detail: "GPU で動かすモデルです。Gemma 4 31B は添削で正しく直せる割合が高い代わりに、12B の約 2 倍の時間とメモリを使います。Hugging Face の MLX 形式のモデル（mlx-community の Qwen・Llama・Gemma など）をフォルダごとモデルのフォルダに置くと選べます。"
                        )
                        .padding(.top, 4)
                        self.describedToggle(
                            "考えてから答える（実験的）",
                            "添削・書き直しの前に AI が考えます。1 文に数分かかることがあるため、通常はオフをおすすめします。",
                            isOn: $localLLMThinking
                        )
                        Text("文章を選択して Ctrl+S → 「添削」で、誤字脱字・変換ミス・文法の誤りを変更箇所ごとに確認して直せます。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if aiBackend.value == .openAI {
                    HStack {
                        SecureField("APIキー", text: $openAiApiKey, prompt: Text("例:sk-xxxxxxxxxxx"))
                        helpButton(
                            helpContent: "OpenAI APIキーはローカルのみで管理され、外部に公開されることはありません。生成の際にAPIを利用するため、課金が発生します。",
                            isPresented: $openAiApiKeyPopover
                        )
                    }
                    TextField("モデル名", text: $openAiModelName, prompt: Text("例: gpt-4o-mini"))
                    TextField("エンドポイント", text: $openAiApiEndpoint, prompt: Text("例: https://api.openai.com/v1/chat/completions"))
                        .help("例: https://api.openai.com/v1/chat/completions\nGemini: https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")

                    HStack {
                        Button("接続テスト") {
                            Task {
                                await testConnection()
                            }
                        }
                        .disabled(connectionTestInProgress || openAiApiKey.value.isEmpty)

                        if connectionTestInProgress {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }

                    if let result = connectionTestResult {
                        Text(result)
                            .foregroundColor(result.contains("成功") ? .green : .red)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Label("いい感じ変換", systemImage: "sparkles")
            }

            Section {
                LabeledContent {
                    HStack {
                        Text("\(self.userDictionary.value.items.count)件のアイテム")
                        Button("編集") {
                            (NSApplication.shared.delegate as? AppDelegate)!.openUserDictionaryEditorWindow()
                        }
                    }
                } label: {
                    Text("ユーザ辞書")
                }
                LabeledContent {
                    HStack {
                        switch self.systemUserDictionaryUpdateMessage {
                        case .none:
                            if let updated = self.systemUserDictionary.value.lastUpdate {
                                let date = updated.formatted(date: .omitted, time: .omitted)
                                Text("最終更新: \(date) / \(self.systemUserDictionary.value.items.count)件のアイテム")
                            } else {
                                Text("未設定")
                            }
                        case .error(let error):
                            Text("読み込みエラー: \(error.localizedDescription)")
                        case .successfulUpdate:
                            Text("読み込みに成功しました / \(self.systemUserDictionary.value.items.count)件のアイテム")
                        }
                        Button("読み込む") {
                            do {
                                let systemUserDictionaryEntries = try SystemUserDictionaryHelper.fetchEntries()
                                self.systemUserDictionary.value.items = systemUserDictionaryEntries.map {
                                    .init(word: $0.phrase, reading: $0.shortcut)
                                }
                                self.systemUserDictionary.value.lastUpdate = .now
                                self.systemUserDictionaryUpdateMessage = .successfulUpdate
                                self.exportUserDictionary()
                            } catch {
                                self.systemUserDictionaryUpdateMessage = .error(error)
                            }
                        }
                        Button("リセット") {
                            self.systemUserDictionary.value.lastUpdate = nil
                            self.systemUserDictionary.value.items = []
                            self.systemUserDictionaryUpdateMessage = nil
                            self.exportUserDictionary()
                        }
                    }
                } label: {
                    Text("システムのユーザ辞書")
                }
            } header: {
                Label("ユーザ辞書", systemImage: "book.closed")
            }

            Section {
                self.describedToggle(
                    "ライブ変換",
                    "入力中の読みを、その場で漢字に変換して表示します。",
                    isOn: $liveConversion
                )
                self.describedToggle(
                    "打ち間違いの訂正候補を出す",
                    "隣のキーを押した・1 文字抜けたなどの打ち間違いに「もしかして」の候補を出します。Tab で入れます。",
                    isOn: $typingTypoCorrection
                )
                DisclosureGroup("続き予測の詳細（従来の設定）") {
                self.describedToggle(
                    "文章の続きを予測する",
                    "入力中、変換の後に続く文章を出します。Tab で確定します。Mac の中の AI（Gemma 4）が予測し、通信はしません。",
                    isOn: $nextTextCompletion
                )
                .help("モデルは ~/Library/Application Support/llm-ime/models/ に置きます。")
                // 続き予測の中の設定なので、続き予測がオンのときだけ出す（オフのときに子の項目の値が見えると、
                // 「続き予測はオフなのに自動生成はオン」のように見えてわかりにくい）
                if $nextTextCompletion.wrappedValue {
                    Group {
                        self.describedToggle(
                            "放置時に本文を生成します",
                            "何も打たずに 3 秒待つと、次の文を書いて出します。空の欄では、その場面のいつもの書き出しを出します。Tab で入れると、さらに続きを書きます。入力メニューからも切り替えられます。",
                            isOn: $nextTextCompletionIdle
                        )
                        if $nextTextCompletionIdle.wrappedValue {
                            self.describedToggle(
                                "AI との会話では、次に送りそうな依頼を出す",
                                "AI の返答が出そろうと、ローカル LLM（いい感じ変換のモデル）で次の依頼を 1 文先に作り、空の欄で手を止めたら書き出しの代わりに出します。「ウィンドウの参照」がオンのときだけ働きます。",
                                isOn: $nextPromptSuggestion
                            )
                            .padding(.leading, 20)
                        }
                        self.modelPicker(
                            key: Config.NextTextCompletionModel.key,
                            detail: "Neural Engine で動かすモデルです。Gemma 4 E4B が標準で、E2B は計算量が約半分（省電力）で精度は少し下がります。gemma4/convert_gemma4.py で変換したものをモデルのフォルダに置くと選べます。"
                        )
                        self.describedToggle(
                            "灰色の文字で表示する",
                            "続きを、入力位置の後ろに灰色の文字で重ねて出します。オフなら、入力位置の下の小さな枠に出します。アプリによっては灰色の文字の位置がずれます。",
                            isOn: $nextTextCompletionInlineGhost
                        )
                    }
                    .padding(.leading, 20)
                }
                }
                HStack {
                    TextField("変換プロフィール", text: $zenzaiProfile, prompt: Text("例：田中太郎/高校生"))
                    helpButton(
                        helpContent: """
                    Zenzaiはあなたのプロフィールを考慮した変換を行うことができます。
                    名前や仕事、趣味などを入力すると、それに合わせた変換が自動で推薦されます。
                    （実験的な機能のため、精度が不十分な場合があります）
                    """,
                        isPresented: $zenzaiProfileHelpPopover
                    )
                }
            } header: {
                Label("変換設定", systemImage: "brain")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - カスタマイズタブ
    @ViewBuilder
    private var customizeTabView: some View {
        Form {
            converterSettingSection(
                title: "入力オプション",
                systemImage: "character.cursor.ibeam",
                keys: [
                    Config.TypeBackSlash.key,
                    Config.TypeHalfSpace.key,
                    Config.OptionDirectFullWidthInput.key,
                    Config.PunctuationStyle.key
                ]
            )

            Section {
                Picker("履歴学習", selection: $learning) {
                    Text("学習する").tag(Config.Learning.Value.inputAndOutput)
                    Text("学習を停止").tag(Config.Learning.Value.onlyOutput)
                    Text("学習を無視").tag(Config.Learning.Value.nothing)
                }
                LabeledContent {
                    HStack {
                        switch learningResetMessage {
                        case .none:
                            EmptyView()
                        case .success:
                            Text("履歴学習データをリセットしました")
                                .foregroundColor(.green)
                        case .error(let message):
                            Text("エラー: \(message)")
                                .foregroundColor(.red)
                        }
                        Spacer()
                        Button("リセット") {
                            showingLearningResetConfirmation = true
                        }
                        .confirmationDialog(
                            "履歴学習データ（場面学習の記録と覚えた語を含む）をリセットしますか？",
                            isPresented: $showingLearningResetConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("リセット", role: .destructive) {
                                resetLearningData()
                            }
                            Button("キャンセル", role: .cancel) {}
                        }
                    }
                } label: {
                    Text("履歴学習データ")
                }
            } header: {
                Label("学習", systemImage: "memorychip")
            }

            self.personalLearningSection
            self.labSection

            Section {
                Picker("入力方式", selection: $inputStyle) {
                    Text("デフォルト").tag(Config.InputStyle.Value.default)
                    Text("かな入力（JIS）").tag(Config.InputStyle.Value.defaultKanaJIS)
                    Text("かな入力（US）").tag(Config.InputStyle.Value.defaultKanaUS)
                    Text("AZIK").tag(Config.InputStyle.Value.defaultAZIK)
                    Text("カスタム").tag(Config.InputStyle.Value.custom)
                }
                if inputStyle.value == .custom {
                    LabeledContent {
                        Button("編集") {
                            showingRomajiTableEditor = true
                        }
                    } label: {
                        Text("カスタム入力テーブル")
                    }
                }
            } header: {
                Label("入力方式", systemImage: "keyboard")
            }

            converterSettingSection(
                title: "キーボード配列",
                systemImage: "keyboard.badge.ellipsis",
                keys: [Config.KeyboardLayout.key]
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 場面学習（llm-ime）

    @ViewBuilder private var windowContextSection: some View {
        Section {
            ForEach([Config.WindowContextEnabled.key, Config.WindowContextExcludedApps.key], id: \.self) { key in
                if let item = self.converterSettingDescriptors[key] { self.converterSettingRow(item) }
            }
            if let status = self.converterSettingDescriptors[Config.windowContextStatusKey] {
                Text(status.title).font(.caption).foregroundColor(.secondary)
            }
            Text("表示中の会話・資料の文字を、変換・訂正・続きの参考にします。取得した文章や画像は保存せず、場面学習の手本にも加えません。図表や写真の内容理解には対応していません。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button("アクセシビリティを許可") {
                    self.updateConverterSetting(key: Config.windowContextAXKey, value: .bool(true))
                }
                Button("画面収録を許可") {
                    self.updateConverterSetting(key: Config.windowContextScreenKey, value: .bool(true))
                }
                Button("状態を更新") { self.reloadConverterSettings() }
            }
        } header: { Label("ウィンドウの参照", systemImage: "macwindow") }
    }

    @ViewBuilder private var assistanceAxesSection:
 some View {
        Section {
            ForEach(AssistanceSettings.axisKeys, id: \.self) { key in
                if let item = self.converterSettingDescriptors[key] { self.converterSettingRow(item) }
            }
            Text("アプリ別の声・記録・Tabは「カスタマイズ」の場面学習にあります。細かな既存の組み合わせは詳細に残します。")
                .font(.caption).foregroundColor(.secondary)
        } header: { Label("助けの設定", systemImage: "slider.horizontal.3") }
    }

    /// Server が返した場面学習の項目（section ごと、Server の順）
    private func personalDescriptors(section: String) -> [ConverterSettingDescriptor] {
        self.converterSettingOrder.compactMap { self.converterSettingDescriptors[$0] }.filter { $0.section == section }
    }

    /// 覚えた語・アプリのスイッチ（オフにすると Server が忘れる・記録しなくなる）。変えたら一覧を取り直す
    private func personalItemToggle(_ setting: ConverterSettingDescriptor) -> some View {
        Toggle(
            setting.title,
            isOn: Binding(
                get: {
                    if case .bool(let value) = self.converterSettingDescriptors[setting.key]?.value {
                        return value
                    }
                    return false
                },
                set: { newValue in
                    self.converterServerClient.updateSetting(key: setting.key, value: .bool(newValue)) { _ in
                        DispatchQueue.main.async {
                            self.reloadConverterSettings()
                        }
                    }
                }
            )
        )
    }

    @ViewBuilder
    private var personalLearningSection: some View {
        Section {
            if let summary = self.converterSettingDescriptors[Config.personalLearningSummaryKey] {
                Text(summary.title).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            self.personalAppRecords(showToggles: self.personalLearning.value)
            DisclosureGroup("詳細（従来の場面学習の設定）") {
            self.describedToggle(
                "使うほど本人に合わせる（場面学習）",
                "どのアプリのどんな欄で、何をどう書いたかを Mac の中だけに記録し、変換と続きの予測をあなたに合わせます。変換の第 1 候補ではない表記を同じ場面で 2 回選ぶと、次からその表記を先に出します（直前の文字が同じところで選び直した表記は 1 回で）。続きの予測では、あなたが前に書いた似た文を手本にします。パスワード管理アプリ、英字だけの入力、パスワードらしい文字列は記録しません。",
                isOn: $personalLearning
            )
            if self.personalLearning.value {
                Group {
                    Toggle("記録を一時停止する（覚えたことは使い続けます）", isOn: $personalLearningPaused)
                    if let retention = self.converterSettingDescriptors[Config.PersonalLearningRetentionDays.key] {
                        self.converterSettingRow(retention)
                    }
                    let words = self.personalDescriptors(section: "場面学習:覚えた語")
                    DisclosureGroup("Shizuku が覚えた語（\(words.count)）") {
                        if words.isEmpty {
                            Text("まだありません。変換の第 1 候補ではない表記を同じ場面で 2 回選ぶと、ここに出ます。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        ForEach(words, id: \.key) { word in
                            self.personalItemToggle(word)
                        }
                        if !words.isEmpty {
                            Text("オフにすると忘れます。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    self.describedToggle(
                        "使い方に合わせて自動で調整する",
                        "続きの予測を出す自信の度合い・手を止めてから続きを出すまでの時間・「もしかして」の出しやすさを、あなたの記録から場面ごとに合わせます。手を止めてから続きを出すまでは、記録がたまると、あなたがいつもより長く手を止めたときにします。変えた後に使われにくくなったら、自動で元に戻します。",
                        isOn: $personalLearningSelfTuning
                    )
                    if self.personalLearningSelfTuning.value, let tuned = self.converterSettingDescriptors[Config.personalLearningTuningSummaryKey] {
                        Text(tuned.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("調整を元に戻す") {
                            self.converterServerClient.updateSetting(key: Config.personalLearningResetTuningKey, value: .bool(true)) { _ in
                                DispatchQueue.main.async {
                                    self.reloadConverterSettings()
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    self.describedToggle(
                        "入力欄に合わせて英数・かなを切り替える",
                        "アプリごとに、入力欄に入ってすぐ自分で英数・かなを切り替えて書き始める癖を覚え、次からは入った時点でそのモードにします（3 回以上そろってから）。切り替わった直後に戻すと、次からはしません。",
                        isOn: $personalInputModeSwitching
                    )
                    let inputModes = self.personalDescriptors(section: "場面学習:入力モード")
                    if !inputModes.isEmpty {
                        DisclosureGroup("覚えた入力モード（\(inputModes.count)）") {
                            ForEach(inputModes, id: \.key) { item in
                                self.personalItemToggle(item)
                            }
                            Text("オフにすると忘れます。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    self.personalAccessibilitySection
                    HStack {
                        Button("一覧を更新") {
                            self.reloadConverterSettings()
                        }
                        Button("記録を書き出す") {
                            self.updateConverterSetting(key: Config.personalLearningExportKey, value: .bool(true))
                        }
                        Spacer()
                        Button("記録と覚えた語をすべて削除", role: .destructive) {
                            self.showingPersonalDeleteConfirmation = true
                        }
                        .confirmationDialog(
                            "場面学習の記録と覚えた語をすべて削除しますか？",
                            isPresented: $showingPersonalDeleteConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("削除", role: .destructive) {
                                self.converterServerClient.updateSetting(key: Config.personalLearningDeleteAllKey, value: .bool(true)) { _ in
                                    DispatchQueue.main.async {
                                        self.reloadConverterSettings()
                                    }
                                }
                            }
                            Button("キャンセル", role: .cancel) {}
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 20)
            }
            }
        } header: {
            Label("場面学習", systemImage: "person.text.rectangle")
        }
    }

    /// 解析と学習: 開始・止める・夜の自動実行・最後の結果・元に戻す（中身は ConverterServer が返す）
    @ViewBuilder
    private var labSection: some View {
        let items = self.personalDescriptors(section: "解析と学習")
        if !items.isEmpty {
            Section {
                Text("記録をまとめて解析し、変換と続きの予測が良くなる設定を探します。直近 2 週間の記録で答え合わせをして、良くなったときだけ使います（元に戻せます）。入力中は止まります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = self.converterSettingDescriptors[Config.labStatusKey] {
                    Text("状態: \(status.title)")
                        .font(.caption)
                }
                HStack {
                    ForEach([Config.labStartKey, Config.labUpperBoundKey, Config.labStopKey, Config.labUndoKey], id: \.self) { key in
                        if let item = self.converterSettingDescriptors[key] {
                            Button(item.title) {
                                self.converterServerClient.updateSetting(key: key, value: .bool(true)) { _ in
                                    DispatchQueue.main.async {
                                        self.reloadConverterSettings()
                                    }
                                }
                            }
                            .disabled(!item.isEnabled)
                        }
                    }
                    Spacer()
                    Button("更新") {
                        self.reloadConverterSettings()
                    }
                }
                .controlSize(.small)
                if let nightly = self.converterSettingDescriptors[Config.LabNightly.key] {
                    DisclosureGroup("夜間実行の詳細") { self.personalItemToggle(nightly) }
                }
                if let summary = self.converterSettingDescriptors[Config.labSummaryKey] {
                    Text("最後の実行: \(summary.title)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let measurement = self.converterSettingDescriptors[Config.labUpperBoundSummaryKey] {
                    Text(measurement.title)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Label("解析と学習", systemImage: "chart.bar.doc.horizontal")
            }
        }
    }

    /// アクセシビリティ（任意）: 許可の状態・使うかのスイッチ・許可の出し方。許可は求めず、システム設定はボタンを押したときだけ開く
    @ViewBuilder
    private var personalAccessibilitySection: some View {
        let items = self.personalDescriptors(section: "場面学習:アクセシビリティ")
        if !items.isEmpty {
            DisclosureGroup("アクセシビリティで場面を細かく見分ける（任意）") {
                ForEach(items, id: \.key) { item in
                    if case .toggle = item.kind {
                        self.personalItemToggle(item)
                    } else {
                        Text("状態: \(item.title)")
                            .font(.caption)
                    }
                }
                Text("""
                    許可すると、入力欄がどのサイトか（ホスト名。例: github.com）と、入力欄の案内文から作った短い符号で場面を分け、\
                    サイトやチャンネルごとの書き方を覚えます。保存するのはこの 2 つだけで、ページの内容・題・案内文そのものは保存しません。\
                    パスワードの欄、記録しないアプリでは読みません。許可しなくても、ほかの学習は今のまま動きます。
                    許可の出し方: システム設定 ＞ プライバシーとセキュリティ ＞ アクセシビリティ で「＋」を押し、\
                    ~/Library/Input Methods/Shizuku.app/Contents/Helpers/ConverterServer/ConverterServer を加えます。\
                    アプリを作り直したり署名し直したりすると許可が外れることがあるので、更新の後はもう一度許可してください。
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("システム設定を開く") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// アプリの名前（Server が返す題「名前（N 件）」から）
    private static func personalAppName(_ setting: ConverterSettingDescriptor) -> String {
        setting.title.components(separatedBy: "（").first ?? setting.title
    }

    /// アプリごとの記録: 記録する・しないのスイッチ（学習がオンのとき）と、そのアプリの記録を消す操作（確かめてから。元に戻せない）
    @ViewBuilder
    private func personalAppRecords(showToggles: Bool) -> some View {
        let apps = self.personalDescriptors(section: "場面学習:アプリ")
        DisclosureGroup("アプリごとの記録（\(apps.count)）") {
            HStack {
                Text("アプリ").frame(width: 150, alignment: .leading)
                Text("声").frame(maxWidth: .infinity)
                Text("記録").frame(width: 48)
                Text("Tab").frame(width: 90)
            }.font(.caption).foregroundColor(.secondary)
            ForEach(apps, id: \.key) { app in
                let appID = String(app.key.dropFirst(Config.personalLearningAppKeyPrefix.count))
                HStack {
                    Text(app.title).frame(width: 150, alignment: .leading)
                    if let voice = self.converterSettingDescriptors[AssistanceSettings.appContentPrefix + appID] {
                        self.converterSettingRow(voice).labelsHidden().frame(maxWidth: .infinity)
                    }
                    self.personalItemToggle(app).labelsHidden().disabled(!showToggles).frame(width: 48)
                    if let tab = self.converterSettingDescriptors[AssistanceSettings.appTabPrefix + appID] {
                        self.converterSettingRow(tab).labelsHidden().frame(width: 90)
                    }
                    Button("このアプリの記録を消す", role: .destructive) {
                        self.personalForgetTarget = app
                    }
                    .controlSize(.small)
                }
            }
            Text(showToggles
                 ? "オフにしたアプリでは記録しません（記録済みのものは残ります）。「このアプリの記録を消す」は、そのアプリの記録と覚えたことをすべて消します。"
                 : "「このアプリの記録を消す」は、そのアプリの記録と覚えたことをすべて消します。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .confirmationDialog(
            "「\(self.personalForgetTarget.map(Self.personalAppName) ?? "")」の記録と覚えたことをすべて消しますか？元に戻せません。",
            isPresented: Binding(
                get: { self.personalForgetTarget != nil },
                set: { if !$0 { self.personalForgetTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("消す", role: .destructive) {
                if let target = self.personalForgetTarget {
                    let app = String(target.key.dropFirst(Config.personalLearningAppKeyPrefix.count))
                    self.converterServerClient.updateSetting(key: Config.personalLearningForgetAppKeyPrefix + app, value: .bool(true)) { _ in
                        DispatchQueue.main.async {
                            self.reloadConverterSettings()
                        }
                    }
                }
                self.personalForgetTarget = nil
            }
            Button("キャンセル", role: .cancel) {
                self.personalForgetTarget = nil
            }
        }
    }

    // MARK: - 詳細設定タブ
    @ViewBuilder
    private var advancedTabView: some View {
        Form {
            Section {
                HStack {
                    TextField("変換プロフィール", text: $zenzaiProfile, prompt: Text("例：田中太郎/高校生"))
                    helpButton(
                        helpContent: """
                    Zenzaiはあなたのプロフィールを考慮した変換を行うことができます。
                    名前や仕事、趣味などを入力すると、それに合わせた変換が自動で推薦されます。
                    （実験的な機能のため、精度が不十分な場合があります）
                    """,
                        isPresented: $zenzaiProfileHelpPopover
                    )
                }
                HStack {
                    TextField(
                        "Zenzaiの推論上限",
                        text: Binding(
                            get: {
                                String(self.$inferenceLimit.wrappedValue)
                            },
                            set: {
                                if let value = Int($0), (1 ... 50).contains(value) {
                                    self.$inferenceLimit.wrappedValue = value
                                }
                            }
                        )
                    )
                    Stepper("", value: $inferenceLimit, in: 1 ... 50)
                        .labelsHidden()
                    helpButton(helpContent: "推論上限を小さくすると、入力中のもたつきが改善されることがあります。", isPresented: $zenzaiInferenceLimitHelpPopover)
                }
            } header: {
                Label("Zenzai設定", systemImage: "cpu")
            }

            Section {
                Toggle("デバッグウィンドウを有効化", isOn: $debugWindow)
                Toggle("開発中の予測入力を有効化", isOn: $debugPredictiveTyping)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("開発中の入力訂正を有効化", isOn: $debugTypoCorrection)
                    if self.debugTypoCorrection.value {
                        HStack {
                            Text(self.debugTypoCorrectionStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if self.debugTypoCorrectionDownloadInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Spacer()
                            switch self.debugTypoCorrectionState {
                            case .downloaded:
                                EmptyView()
                            case .failed, .notDownloaded:
                                // llm-ime: 完全ローカル版ではダウンロードしない
                                Text("ダウンロード無効（ローカル版）")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if case .failed = self.debugTypoCorrectionState,
                           let errorMessage = self.debugTypoCorrectionErrorMessage {
                            Text(errorMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .onAppear {
                    guard self.debugTypoCorrection.value else {
                        return
                    }
                    Task { @MainActor in
                        await self.refreshDebugTypoCorrectionState()
                    }
                }
                .onChange(of: self.debugTypoCorrection.value) { enabled in
                    if enabled {
                        Task { @MainActor in
                            await self.refreshDebugTypoCorrectionState()
                        }
                    } else {
                        self.debugTypoCorrectionState = .notDownloaded
                        self.debugTypoCorrectionDownloadInProgress = false
                        self.debugTypoCorrectionErrorMessage = nil
                    }
                }
                Picker("パーソナライズ", selection: $zenzaiPersonalizationLevel) {
                    Text("オフ").tag(Config.ZenzaiPersonalizationLevel.Value.off)
                    Text("弱く").tag(Config.ZenzaiPersonalizationLevel.Value.soft)
                    Text("普通").tag(Config.ZenzaiPersonalizationLevel.Value.normal)
                    Text("強く").tag(Config.ZenzaiPersonalizationLevel.Value.hard)
                }
                LabeledContent("アプリデータ") {
                    HStack {
                        Button("Finderで開く") {
                            self.openDataDirectoryInFinder()
                        }
                    }
                }
                LabeledContent("Converter Process") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("再起動") {
                            self.restartConverterProcess()
                        }
                        .disabled(self.converterProcessRestartInProgress)
                        if self.converterProcessRestartInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let converterProcessRestartMessage {
                            Text(converterProcessRestartMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Label("開発者向け設定", systemImage: "hammer")
            }

            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shizuku")
                            .font(.title2)
                            .bold()
                        Text("Mac の中だけで動く AI で、変換・続きの予測・添削をする日本語入力")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("バージョン") {
                    Text(self.versionText)
                        .monospaced()
                        .copyable([self.versionText])
                }
                .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("謝辞")
                    Text("""
                        かな漢字変換エンジンと入力の土台に、Miwa Keita さんによる azooKey（azooKey-Desktop・\
                        AzooKeyKanaKanjiConverter、MIT License）と、変換用モデル zenz を使っています。
                        """)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Label("Shizuku について", systemImage: "drop")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    ConfigWindow()
}
