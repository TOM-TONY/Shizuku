import CryptoKit
import Foundation

// llm-ime: アップデートの署名鍵（Ed25519）。秘密鍵は標準入力から base64 で受け取る（コマンドラインに出さない）。
//   update_key generate                     新しい鍵を作り、{"private": …, "public": …} を出す
//   update_key public  < 秘密鍵             公開鍵（base64）を出す
//   update_key sign <zip> <build> <url> < 秘密鍵
//                                          zip の大きさ・SHA-256 と、update.json の署名を JSON で出す
// 署名する内容は管理アプリの UpdateInfo.signedMessage と同じ。

func readPrivateKey() -> Curve25519.Signing.PrivateKey {
    let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let data = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        FileHandle.standardError.write(Data("秘密鍵を読めません\n".utf8))
        exit(1)
    }
    return key
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
        try? handle.close()
    }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func printJSON(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    printJSON(["private": key.rawRepresentation.base64EncodedString(), "public": key.publicKey.rawRepresentation.base64EncodedString()])
case "public":
    print(readPrivateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 5:
    let zip = URL(fileURLWithPath: arguments[2])
    let build = arguments[3], url = arguments[4]
    let key = readPrivateKey()
    let size = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as! NSNumber).int64Value
    let hash = try sha256(of: zip)
    let message = Data("llm-ime-update\n\(build)\n\(url)\n\(size)\n\(hash)".utf8)
    let signature = try key.signature(for: message)
    printJSON(["size": size, "sha256": hash, "signature": signature.base64EncodedString()])
default:
    FileHandle.standardError.write(Data("usage: update_key generate | public | sign <zip> <build> <url>\n".utf8))
    exit(2)
}
