import Foundation

// 開発用の通し確認専用。通常のdefaultsコマンドにはApp Groupの権限がないため、同じ署名で5キーだけを退避・復元する。
let suite = "YOURTEAMID.dev.tomonari.inputmethod.Shizuku"
let prefix = "dev.tomonari.inputmethod.Shizuku.preference.assistance."
let keys = ["timing", "content", "memory", "apps", "migration"].map { prefix + $0 }
guard let defaults = UserDefaults(suiteName: suite) else { fatalError("設定の保存先がありません") }
let arguments = Array(CommandLine.arguments.dropFirst())
func values() -> [String: Any] { Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0) ?? NSNull()) }) }
if arguments.first == "--restore", arguments.count == 2 {
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[1]))) as! [String: Any]
    precondition(Set(saved.keys) == Set(keys))
    for key in keys {
        let value = saved[key]!
        precondition(value is NSNull || value is String || (key == prefix + "migration" && value is NSNumber))
        if value is NSNull { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
    }
    _ = defaults.synchronize() // App Groupでは戻り値を成功判定にせず、親が別プロセスで読み直す。
}
let data = try JSONSerialization.data(withJSONObject: values(), options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
