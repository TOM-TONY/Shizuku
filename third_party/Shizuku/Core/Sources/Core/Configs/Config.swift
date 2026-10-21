import Foundation

/// namespace for `Config`
public enum Config {
    nonisolated(unsafe) public static let userDefaults: UserDefaults = {
        if WindowContextTestRuntime.root != nil {
            return UserDefaults(suiteName: "dev.tomonari.xpcprobe.volatile." + UUID().uuidString)!
        }
        #if os(macOS)
        return UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        #else
        return .standard
        #endif
    }()

    public static func object(forKey key: String) -> Any? {
        if let value = Self.userDefaults.object(forKey: key) {
            return value
        }
        return WindowContextTestRuntime.root == nil ? UserDefaults.standard.object(forKey: key) : nil
    }

    public static func data(forKey key: String) -> Data? {
        if let value = Self.userDefaults.data(forKey: key) {
            return value
        }
        return WindowContextTestRuntime.root == nil ? UserDefaults.standard.data(forKey: key) : nil
    }

    public static func string(forKey key: String) -> String? {
        if let value = Self.userDefaults.string(forKey: key) {
            return value
        }
        return WindowContextTestRuntime.root == nil ? UserDefaults.standard.string(forKey: key) : nil
    }

    public static func set(_ value: Any?, forKey key: String) {
        if WindowContextTestRuntime.root != nil {
            var values = Self.userDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
            values[key] = value
            Self.userDefaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
            return
        }
        Self.userDefaults.set(value, forKey: key)
    }
}

public protocol ConfigItem<Value> {
    static var key: String { get }
    associatedtype Value: Codable
    var value: Value { get nonmutating set }
}
