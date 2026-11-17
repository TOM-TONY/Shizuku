import Cocoa

/// ConverterServer がキーに応答しない間の状態と、その表示。
///
/// 入力欄ごとのコントローラは、応答待ちのキーが進まないまま上限を超えたときに
/// `markUnavailable()` を呼ぶ。応答しない間、コントローラはキーを consume せず
/// アプリへそのまま渡す（打鍵が表示されないまま溜まり続けるのを避ける）。
/// ここでは Server の復帰を確かめ続け、復帰したら元の経路へ戻す。
@MainActor
final class ConverterServerAvailability {
    static let shared = ConverterServerAvailability()

    private static let probeInterval: TimeInterval = 1
    private static let maximumProbeInterval: TimeInterval = 8
    private static let probeTimeout: TimeInterval = 2
    private static let waitingNoticeDuration: TimeInterval = 6
    private static let recoveredNoticeDuration: TimeInterval = 1.5
    private static let waitingText = "変換エンジンの応答を待っています。戻るまで、キーはそのまま入力されます"

    private(set) var isUnavailable = false
    private var unavailableSince: TimeInterval = 0
    /// 状態が変わるたびに進める。古い確認や、古い「消す」予約を無視するために使う
    private var generation: UInt64 = 0
    private var notice: ServerStatusNotice?
    private var noticeGeneration: UInt64 = 0
    private var noticeShownAt: TimeInterval = 0
    private var nextProbeInterval = ConverterServerAvailability.probeInterval

    func markUnavailable() {
        guard !self.isUnavailable else { return }
        self.isUnavailable = true
        self.unavailableSince = ProcessInfo.processInfo.systemUptime
        self.generation &+= 1
        self.nextProbeInterval = Self.probeInterval
        InputTrace.event(.transport, controller: 0, reason: .serverUnavailable)
        self.showNotice(Self.waitingText, duration: Self.waitingNoticeDuration)
        self.scheduleProbe(after: Self.probeInterval, generation: self.generation)
    }

    /// 応答しない間にキーが打たれた。知らせが消えていれば出し直し、復帰の確認を急ぐ。
    func noteKeyWhileUnavailable() {
        guard self.isUnavailable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - self.noticeShownAt > Self.waitingNoticeDuration {
            self.showNotice(Self.waitingText, duration: Self.waitingNoticeDuration)
        }
        if self.nextProbeInterval > Self.probeInterval {
            // 間隔を延ばした確認の予約は世代で無効にして、すぐ確かめ直す
            self.nextProbeInterval = Self.probeInterval
            self.generation &+= 1
            self.scheduleProbe(after: Self.probeInterval, generation: self.generation)
        }
    }

    private func scheduleProbe(after delay: TimeInterval, generation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isUnavailable, self.generation == generation else { return }
            ConverterServerClient.probeServer(timeout: Self.probeTimeout) { [weak self] alive in
                guard let self, self.isUnavailable, self.generation == generation else { return }
                if alive {
                    self.markRecovered()
                } else {
                    // 戻らない Server を毎秒起こし続けない
                    self.nextProbeInterval = min(self.nextProbeInterval * 2, Self.maximumProbeInterval)
                    self.scheduleProbe(after: self.nextProbeInterval, generation: generation)
                }
            }
        }
    }

    private func markRecovered() {
        self.isUnavailable = false
        self.generation &+= 1
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - self.unavailableSince) * 1000)
        InputTrace.persistent(.serverRecovered, controller: 0, milliseconds: milliseconds)
        self.showNotice("変換を再開しました", duration: Self.recoveredNoticeDuration)
    }

    private func showNotice(_ text: String, duration: TimeInterval) {
        let notice = self.notice ?? ServerStatusNotice()
        self.notice = notice
        notice.show(text)
        self.noticeShownAt = ProcessInfo.processInfo.systemUptime
        self.noticeGeneration &+= 1
        let shown = self.noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.noticeGeneration == shown else { return }
            self.notice?.orderOut(nil)
        }
    }
}

/// 画面上部の中央に出す短い知らせ。入力先のアプリには問い合わせず、キーもマウスも受け取らない
private final class ServerStatusNotice: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.level = .statusBar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        self.label.font = .systemFont(ofSize: 13)
        self.label.textColor = .labelColor
        self.label.lineBreakMode = .byTruncatingTail
        self.label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(self.label)
        NSLayoutConstraint.activate([
            self.label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            self.label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            self.label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        self.contentView = background
    }

    func show(_ text: String) {
        self.label.stringValue = text
        // キーを受けているウィンドウのある画面（取れなければ主画面）の、メニューバーのすぐ下
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(self.label.intrinsicContentSize.width + 28, visible.width - 40), height: 34)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10)
        self.setFrame(NSRect(origin: origin, size: size), display: true)
        self.orderFrontRegardless()
    }
}
