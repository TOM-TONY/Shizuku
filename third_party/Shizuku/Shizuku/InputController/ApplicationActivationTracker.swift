import Cocoa

/// llm-ime: 場面学習のために、直前に使っていたアプリ（どこから来たか）を覚えておく。
/// NSWorkspace のアプリ切り替えの通知はサンドボックスの中でも受け取れる。IME 本体のプロセスで 1 つだけ動かす
@MainActor
final class ApplicationActivationTracker {
    static let shared = ApplicationActivationTracker()

    private(set) var current: String?
    private(set) var previous: String?
    private var observer: NSObjectProtocol?

    func start() {
        guard self.observer == nil else {
            return
        }
        self.current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                ApplicationActivationTracker.shared.didActivate(bundleID)
            }
        }
    }

    private func didActivate(_ bundleID: String?) {
        guard let bundleID, bundleID != self.current else {
            return
        }
        self.previous = self.current
        self.current = bundleID
    }

    /// bundleID のアプリの前に使っていたアプリ
    func previousApplication(before bundleID: String?) -> String? {
        if let bundleID, bundleID == self.current {
            return self.previous
        }
        return self.current
    }
}
