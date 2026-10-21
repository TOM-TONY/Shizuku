import Cocoa
import Core
import InputMethodKit

extension ShizukuInputController {
    // MARK: - Settings and Menu Items

    func setupMenu() {
        self.appMenu.autoenablesItems = true
        self.liveConversionToggleMenuItem = NSMenuItem(title: "ライブ変換", action: #selector(self.toggleLiveConversion(_:)), keyEquivalent: "")
        self.appMenu.addItem(self.liveConversionToggleMenuItem)
        self.idleCompletionToggleMenuItem = NSMenuItem(title: "放置で続きを自動生成", action: #selector(self.toggleIdleCompletion(_:)), keyEquivalent: "")
        self.idleCompletionToggleMenuItem.state = Self.isIdleCompletionEnabled ? .on : .off
        self.appMenu.addItem(self.idleCompletionToggleMenuItem)
        self.transformSelectedTextMenuItem = NSMenuItem(title: TransformMenuTitle.normal, action: #selector(self.performTransformSelectedText(_:)), keyEquivalent: "s")
        self.transformSelectedTextMenuItem.keyEquivalentModifierMask = [.control]
        self.transformSelectedTextMenuItem.target = self
        self.appMenu.addItem(self.transformSelectedTextMenuItem)
        self.quoteMenuItem = NSMenuItem(title: "前に書いた文を入れる…", action: #selector(self.summonQuoteChoices(_:)), keyEquivalent: "")
        self.quoteMenuItem.target = self
        self.appMenu.addItem(self.quoteMenuItem)
        self.teachMenuItem = NSMenuItem(title: "この欄の手本として覚える", action: #selector(self.teachSelection(_:)), keyEquivalent: "")
        self.teachMenuItem.target = self; self.appMenu.addItem(self.teachMenuItem)
        self.undoTeachMenuItem = NSMenuItem(title: "手本を取り消す（10秒以内）", action: #selector(self.undoTaughtSelection(_:)), keyEquivalent: "")
        self.undoTeachMenuItem.target = self; self.appMenu.addItem(self.undoTeachMenuItem)
        // llm-ime: 項目は init で作り、選んだときの処理だけで除外の設定を書く
        self.windowExcludeMenuItem = NSMenuItem(title: "このアプリの画面を参照しない", action: #selector(self.excludeWindowContextForApp(_:)), keyEquivalent: "")
        self.windowExcludeMenuItem.target = self; self.appMenu.addItem(self.windowExcludeMenuItem)
        self.appMenu.addItem(NSMenuItem.separator())
        self.appMenu.addItem(NSMenuItem(title: "設定…", action: #selector(self.openConfigWindow(_:)), keyEquivalent: ""))
        // llm-ime: 管理アプリ（アップデートの確認・アンインストール）が入っているときだけ出す
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.managerBundleIdentifier) != nil {
            self.appMenu.addItem(NSMenuItem(title: "アップデートを確認…", action: #selector(self.openManagerApp(_:)), keyEquivalent: ""))
        }
        self.updateTransformSelectedTextMenuItemEnabledState()
    }

    @objc func toggleLiveConversion(_ sender: Any) {
        self.appendDebugMessage("\(#line): toggleLiveConversion")
        let config = Config.LiveConversion()
        config.value = !self.liveConversionEnabled
        self.updateLiveConversionToggleMenuItem(newValue: config.value)
    }

    /// llm-ime: 放置で続きを自動生成を切り替える。続き予測がオフならオンにする（続き予測の中の機能なので）
    @MainActor @objc func toggleIdleCompletion(_ sender: Any) {
        if Self.isIdleCompletionEnabled {
            Config.NextTextCompletionIdle().value = false
            self.cancelIdleCompletion()
        } else {
            Config.NextTextCompletionIdle().value = true
            Config.NextTextCompletion().value = true
        }
        self.idleCompletionToggleMenuItem.state = Self.isIdleCompletionEnabled ? .on : .off
    }

    func updateLiveConversionToggleMenuItem(newValue: Bool) {
        self.liveConversionToggleMenuItem.state = newValue ? .on : .off
        self.liveConversionToggleMenuItem.title = "ライブ変換"
    }

    private enum TransformMenuTitle {
        static let normal = "いい感じ変換"
        static let noBackend = "いい感じ変換（無効/バックエンドなし）"
    }

    @MainActor @objc func performTransformSelectedText(_ sender: Any) {
        let aiBackendEnabled = Config.AIBackendPreference().value != .off
        self.updateTransformSelectedTextMenuItemTitle(aiBackendEnabled: aiBackendEnabled)
        guard aiBackendEnabled else {
            return
        }
        guard !self.isPromptWindowVisible else {
            return
        }
        guard let client = self.client() else {
            return
        }
        let hasSelection = client.selectedRange().length > 0
        if hasSelection {
            self.showPromptInputWindow()
            return
        }
        _ = self.requestPredictiveSuggestionWithConverterServer(client: client)
    }

    @MainActor @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Setters can make IMK rebuild the menu and deactivate this controller. Return availability only.
        if menuItem == self.undoTeachMenuItem {
            let available = self.teachingUndoReceipt.map { Date() <= $0.until } ?? false
            return available && PersonalLearner.isRecording
        }
        if menuItem == self.teachMenuItem {
            // IMK also validates this menu between key events. Query the selection only
            // in teachSelection, after the user actually invokes the action.
            return self.canUsePersonalMenu
        }
        if menuItem == self.quoteMenuItem {
            return self.canUsePersonalMenu
        }
        if menuItem == self.windowExcludeMenuItem {
            return Config.WindowContextEnabled().value && self.canExcludeWindowContext
        }
        if menuItem == self.idleCompletionToggleMenuItem {
            return true
        }
        guard menuItem == self.transformSelectedTextMenuItem else {
            return true
        }
        return self.canPerformTransformSelectedText
    }

    func updateTransformSelectedTextMenuItemEnabledState() {
        let aiBackendEnabled = Config.AIBackendPreference().value != .off
        self.updateTransformSelectedTextMenuItemTitle(aiBackendEnabled: aiBackendEnabled)
        self.transformSelectedTextMenuItem.isEnabled = self.canPerformTransformSelectedText
    }

    private var canPerformTransformSelectedText: Bool {
        // performTransformSelectedText revalidates the live client on invocation.
        !self.isPromptWindowVisible
    }

    private func updateTransformSelectedTextMenuItemTitle(aiBackendEnabled: Bool) {
        self.transformSelectedTextMenuItem.title = aiBackendEnabled ? TransformMenuTitle.normal : TransformMenuTitle.noBackend
    }

    @objc func openConfigWindow(_ sender: Any) {
        (NSApplication.shared.delegate as? AppDelegate)!.openConfigWindow()
    }

    /// llm-ime: 配布版の管理アプリ（開くとアップデートを確認する。IME 本体は通信しない）
    static let managerBundleIdentifier = "dev.tomonari.llm-ime.manager"

    @objc func openManagerApp(_ sender: Any) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.managerBundleIdentifier) else {
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

}
