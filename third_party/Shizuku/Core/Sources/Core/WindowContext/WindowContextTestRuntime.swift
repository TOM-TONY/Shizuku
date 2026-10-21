import Foundation

/// Storage isolation is available only to the dedicated synthetic executable mode.
public enum WindowContextTestRuntime {
    public static let flag = "--window-context-e2e-self-test"
    public static var operatingSystemFixture: Bool {
        Bundle.main.bundleIdentifier == "dev.tomonari.xpcprobe.window-os"
            && Bundle.main.object(forInfoDictionaryKey: "WindowContextOperatingSystemTest") as? Bool == true
    }
    public static let root: URL? = {
        guard CommandLine.arguments.contains(flag) || operatingSystemFixture else { return nil }
        guard let path = ProcessInfo.processInfo.environment["LLM_IME_WINDOW_TEST_ROOT"], path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path + "/.synthetic-window-test") else {
            fatalError("Synthetic window tests require an explicitly prepared isolated root")
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }()
}
