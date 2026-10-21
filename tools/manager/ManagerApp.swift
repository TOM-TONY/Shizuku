import AppKit
import SwiftUI

// llm-ime 管理アプリの画面。DMG から開いたときはインストール、~/Applications のものを開いたときは
// 状態の表示・アップデート・アンインストール。

@MainActor
final class ManagerModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case installed
        case updated
        case uninstalled
        case failed(String)
    }

    enum UpdateState: Equatable {
        case unknown
        case checking
        case upToDate
        case available(UpdateInfo)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var selected: Set<String> = []
    @Published var update: UpdateState = .unknown
    @Published var autoCheck = true
    let embeddingWarning = Main.embeddingWarning

    let system = SystemInfo.current()
    let payload = Paths.payload()
    let manifest: Manifest?
    let isInstalledCopy = Paths.isRunningInstalledCopy

    init(justUpdated: Bool) {
        if let payload, let data = try? Data(contentsOf: payload.appendingPathComponent("manifest.json")) {
            self.manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        } else {
            self.manifest = nil
        }
        self.selected = self.manifest?.recommendedModelNames(memoryGB: self.system.memoryGB) ?? []
        if self.isInstalledCopy {
            self.autoCheck = Installer.isAutoUpdateCheckEnabled
        }
        if justUpdated {
            self.phase = .updated
        }
    }

    var currentVersion: String {
        Updater.currentVersion?.version ?? "?"
    }

    var installedIMEVersion: String? {
        BundleVersion(bundle: Paths.installedIME)?.version
    }

    var selectedBytes: Int64 {
        self.selectedModels.map(\.bytes).reduce(0, +)
    }

    var selectedModels: [Manifest.Model] {
        self.manifest?.selectedModels(self.selected) ?? []
    }

    private func report() -> Installer.Report {
        { message, fraction in
            Task { @MainActor in
                self.phase = .working(message)
                self.progress = fraction
            }
        }
    }

    func install() {
        guard let payload, let manifest else {
            return
        }
        let models = manifest.selectedModels(self.selected)
        let autoCheck = self.autoCheck
        let report = self.report()
        self.progress = 0
        self.phase = .working("準備しています…")
        Task.detached {
            do {
                try Installer.installFromDMG(payload: payload, models: models, autoCheck: autoCheck, report: report)
                await MainActor.run { self.phase = .installed }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func checkForUpdate() {
        self.update = .checking
        Task {
            do {
                if let info = try await Updater.check() {
                    self.update = .available(info)
                } else {
                    self.update = .upToDate
                }
            } catch {
                self.update = .failed(error.localizedDescription)
            }
        }
    }

    func applyUpdate(_ info: UpdateInfo) {
        let report = self.report()
        self.progress = 0
        self.phase = .working("ダウンロードしています…")
        Task.detached {
            do {
                try await Updater.apply(info, report: report)
                await MainActor.run { Updater.relaunch() }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func setAutoCheck(_ enabled: Bool) {
        do {
            try Installer.setAutoUpdateCheck(enabled)
            self.autoCheck = enabled
        } catch {
            self.phase = .failed(error.localizedDescription)
        }
    }

    func uninstall(removeModels: Bool) {
        self.phase = .working("取り除いています…")
        Task.detached {
            do {
                try Installer.uninstall(removeModels: removeModels)
                await MainActor.run { self.phase = .uninstalled }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }
}

struct ManagerView: View {
    @ObservedObject var model: ManagerModel
    @State private var confirmUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shizuku")
                .font(.title2.bold())
            Text("Mac の中だけで動く AI で、かな漢字変換・続きの予測・添削・書き直しをする日本語入力です。入力した文章は外に送りません（通信するのはアップデートの確認だけです）。")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if let warning = self.model.embeddingWarning, self.model.phase != .uninstalled {
                Text(warning + " アップデートとアンインストールは引き続き使えます。")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch self.model.phase {
            case .idle:
                if self.model.isInstalledCopy {
                    self.statusView
                } else {
                    self.installView
                }
            case .working(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                    ProgressView(value: self.model.progress)
                    Text("数分かかることがあります。").font(.callout).foregroundStyle(.secondary)
                }
            case .installed:
                self.installedView
            case .updated:
                VStack(alignment: .leading, spacing: 10) {
                    Text("バージョン \(self.model.currentVersion) にアップデートしました。").font(.headline)
                    Text("入力中のアプリでは、次に文字を入力したときから新しい版になります。")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("OK") { self.model.phase = .idle }
                        .keyboardShortcut(.defaultAction)
                }
            case .uninstalled:
                Text("取り除きました。入力ソースの一覧に残っている場合は、システム設定の「キーボード」→「入力ソース」から削除してください。")
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("うまくいきませんでした").font(.headline)
                    Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("戻る") { self.model.phase = .idle }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 360)
        .onAppear {
            if self.model.isInstalledCopy, self.model.phase == .idle {
                self.model.checkForUpdate()
            }
        }
    }

    // MARK: - ~/Applications の管理アプリ

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("バージョン \(self.model.currentVersion)").font(.headline)
            if self.model.installedIMEVersion == nil {
                Text("IME 本体が入っていません。DMG の中の「Shizuku」を開いて、インストールし直してください。")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch self.model.update {
            case .unknown, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("アップデートを確認しています…")
                }
            case .upToDate:
                HStack {
                    Text("最新の版です。")
                    Button("もう一度確認") { self.model.checkForUpdate() }
                }
            case .available(let info):
                VStack(alignment: .leading, spacing: 8) {
                    Text("新しいバージョン \(info.version) があります（\(formatBytes(info.size))）。").font(.headline)
                    if let notes = info.notes, !notes.isEmpty {
                        ScrollView {
                            Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                    }
                    Button("アップデート") { self.model.applyUpdate(info) }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("もう一度確認") { self.model.checkForUpdate() }
                }
            }
            Toggle("1 日 1 回、自動でアップデートを確認する", isOn: Binding(
                get: { self.model.autoCheck },
                set: { self.model.setAutoCheck($0) }
            ))
            HStack {
                Spacer()
                Button("アンインストール…") { self.confirmUninstall = true }
            }
            .confirmationDialog("Shizuku を取り除きますか？", isPresented: self.$confirmUninstall) {
                Button("IME だけ取り除く") { self.model.uninstall(removeModels: false) }
                Button("モデルも削除する", role: .destructive) { self.model.uninstall(removeModels: true) }
            }
        }
    }

    // MARK: - DMG から開いたとき

    @ViewBuilder
    private var installView: some View {
        let system = self.model.system
        if !system.isAppleSilicon || !system.osOK {
            Text("この Mac では使えません。Apple シリコン（M1 以降）の Mac と macOS 15 以降が必要です。")
                .foregroundStyle(.red)
        } else if let manifest = self.model.manifest {
            Text("入れるモデル（この Mac のメモリ: \(system.memoryGB) GB）").font(.headline)
            ForEach(manifest.models) { item in
                Toggle(isOn: Binding(
                    get: { item.isRequired || self.model.selected.contains(item.name) },
                    set: { on in
                        guard !item.isRequired else { return }
                        if on {
                            self.model.selected.insert(item.name)
                        } else {
                            self.model.selected.remove(item.name)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.title)（\(formatBytes(item.bytes))）\(item.isRequired ? "・必須" : "")")
                        Text(item.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(item.isRequired)
            }
            Toggle("1 日 1 回、自動でアップデートを確認する", isOn: self.$model.autoCheck)
            let enough = system.freeBytes > self.model.selectedBytes + 3_000_000_000
            Text("必要な空き容量: \(formatBytes(self.model.selectedBytes + 2_000_000_000))（空き: \(formatBytes(system.freeBytes))）")
                .font(.callout)
                .foregroundStyle(enough ? Color.secondary : Color.red)
            Button(FileManager.default.fileExists(atPath: Paths.installedIME.path) ? "入れ直す" : "インストール") { self.model.install() }
                .keyboardShortcut(.defaultAction)
                .disabled(!enough)
        } else {
            Text("インストールする物が見つかりません。ディスクイメージ（DMG）を開いたまま、その中の「Shizuku」を開いてください。")
                .foregroundStyle(.red)
        }
    }

    private var installedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("インストールしました。あと少しです。").font(.headline)
            Text("""
            1. 下のボタンでシステム設定を開き、「入力ソース」の「編集…」を押す
            2. 左下の「＋」→「日本語」→「Shizuku (日本語)」を選んで「追加」
               （英字入力用に「Shizuku (English)」も追加しておくと便利です）
            3. メニューバーの入力メニューから Shizuku を選ぶ
            4. 入力メニューの Shizuku →「設定…」で「文章の続きを予測する」をオン、「いい感じ変換」で「ローカル LLM」を選ぶ
            """)
            .fixedSize(horizontal: false, vertical: true)
            Text("最初の変換と、最初の続きの予測は、準備に 1〜2 分かかります。この管理アプリは「アプリケーション」フォルダ（ホーム）に入りました。アップデートやアンインストールはそこから開いてください。DMG は取り出してかまいません。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("システム設定のキーボードを開く") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

struct ManagerApp: App {
    @StateObject private var model = ManagerModel(justUpdated: CommandLine.arguments.contains("--updated"))

    var body: some Scene {
        WindowGroup("Shizuku") {
            ManagerView(model: self.model)
        }
        .windowResizability(.contentSize)
    }
}

/// 画面なしの操作（確認・試験用）
///   --background-check           1 日 1 回の自動確認（新しい版があれば管理アプリを開く）
///   --cli-check                  新しい版があるか表示する
///   --cli-update                 新しい版を入れる
///   --cli-install [モデル名…]     DMG からインストールする
enum CommandLineTool {
    static func runAsync(_ body: @escaping @Sendable () async throws -> Void) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: Int32 = 0
        Task.detached {
            do {
                try await body()
            } catch {
                print("失敗: \(error.localizedDescription)")
                status = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return status
    }

    static let printReport: Installer.Report = { message, fraction in
        print(String(format: "[%3.0f%%] ", fraction * 100) + message)
    }
}

@main
@MainActor
enum Main {
    private(set) static var embeddingWarning: String?

    static func main() {
        let arguments = CommandLine.arguments
        // 旧版の CLI 更新は開き直さない。新版がどの入口で起動されても先に不足分を補う。
        if Paths.isRunningInstalledCopy {
            Self.embeddingWarning = BundledModels.prepare(report: CommandLineTool.printReport)
        }
        #if MANAGER_DEVELOPMENT
        if ManagerDevelopment.isIsolated && arguments.contains("--test-startup-only") { return }
        #endif
        if arguments.contains("--background-check") {
            exit(Updater.backgroundCheck())
        }
        if arguments.contains("--cli-check") {
            exit(CommandLineTool.runAsync {
                if let info = try await Updater.check() {
                    print("新しい版: \(info.version)（\(info.build)）\(formatBytes(info.size))")
                } else {
                    print("最新の版です（\(Updater.currentVersion?.version ?? "?")）")
                }
            })
        }
        if arguments.contains("--cli-update") {
            exit(CommandLineTool.runAsync {
                guard let info = try await Updater.check() else {
                    print("最新の版です")
                    return
                }
                try await Updater.apply(info, report: CommandLineTool.printReport)
                print("完了: \(info.version)")
            })
        }
        if let index = arguments.firstIndex(of: "--cli-install") {
            let names = Array(arguments[(index + 1)...])
            exit(CommandLineTool.runAsync {
                guard let payload = Paths.payload(),
                      let data = try? Data(contentsOf: payload.appendingPathComponent("manifest.json")) else {
                    throw ManagerError.message("インストールする物が見つかりません")
                }
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                let selected = Set(names.isEmpty ? manifest.models.map(\.name) : names)
                let models = manifest.selectedModels(selected)
                try Installer.installFromDMG(payload: payload, models: models, autoCheck: true, report: CommandLineTool.printReport)
                print("完了")
            })
        }
        ManagerApp.main()
    }
}
