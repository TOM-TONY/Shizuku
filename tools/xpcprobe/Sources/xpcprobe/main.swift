// 稼働中の ConverterServer に XPC でキー列を送り、各キーの応答（状態・effect・marked text・候補窓）を表示する。
// 使い方: xpcprobe [--live] [--complete] "kyou" "<BS>" "u" ...
//   各引数は 1 文字ずつのキー入力。<BS> はバックスペース、<SP> はスペース、<CR> はリターン、<TAB> はタブ。
//   --complete: 続き予測を有効にし、各キーの後に予測の完了を待って結果を表示する（IME と同じ流れ）。
//   --ai-local: いい感じ変換をローカル LLM にする。<SUGGEST>（Ctrl+S）で候補を要求して表示する。
//   --transform <文章> <指示>: ローカル LLM で文章を書き換えて表示する（キー入力はしない）。
//   --style <指示>: いい感じ変換の指示（設定）を変える（空文字で既定に戻す）。
//   --proofread <文章>: ローカル LLM で添削し、変更箇所を表示する（キー入力はしない）。
//   --left <文章>: カーソルの前にある文章（左文脈）として送る。
//   --idle <文章>: 何も入力していない状態で、その文章の続きを予測する。
//   --draft <文章>: 文章を書き進める補完（1 文ずつ 3 文まで）。
//   --scene <指定>: 場面学習のメタ情報を各キーに載せる（IME 本体と同じ）。例: "app=com.tinyspeck.slackmacgap,len=0,empty=1,mono=0,prev=com.apple.mail"
//   --personal on|off: 場面学習のスイッチを切り替える（設定画面と同じ経路）。--personal-reset: 記録と覚えた語をすべて消す。
//   --learned: 場面学習の設定画面の項目（覚えた語・アプリ・集計）を表示する。--forget <文字列>: 題にその文字列を含む覚えた語を忘れる。
//   --export <パス>: 場面学習の記録を JSON Lines で書き出す（評価用。本人の文章を含むので git 管理外の場所へ）。
//   --get <文字列>: キーにその文字列を含む設定の値を表示する。--set <キー>=<値>: 設定を変える（true/false/整数/文字列）。
//   --observe-mode <アプリ>=<english|japanese>[!],...: 入力欄に入って最初に打ったときの入力モードの観測を送る（! は自分で切り替えた）。
//   --preferred-mode <アプリ>: そのアプリでいつも使う入力モード（IME 本体が入力欄に入ったときに尋ねるもの）を表示する。
//   キー: <DOWN> <UP> <LEFT> <RIGHT> <S-LEFT> <S-RIGHT>（文節の伸縮）<ESC> <F7>（カタカナ）、数字 1〜9 は候補の番号。
//   <BS=n>: キーは送らず、次のキーの場面の情報に「確定の直後にアプリで押したバックスペースの数 n」を載せる（言い直しを試す。--scene と使う）
//   <WAIT=秒>: キーは送らず、その秒数だけ待つ（手を止めた長さの記録を試す）
//   <MARK>: 次のキーを送る直前の時刻を標準エラーに出す（解析と学習が止まるまでの時間を測る）
//   <SKEL>: キーの列の途中で、空の欄の書き出しを尋ねる（そのあとのキーで「使われなかった」になる）
//   --skeleton: キーを送った後、空の欄のいつもの書き出し（骨組み）を --scene の場面で尋ねて表示する。--accept-skeleton で Tab で入れたことにする
import Core
import Foundation

@objc protocol ConverterServerXPCProtocol {
    func openSession(with reply: @escaping @Sendable (String) -> Void)
    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void)
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}

let args = Array(CommandLine.arguments.dropFirst())
let live = args.contains("--live")
let complete = args.contains("--complete")
let aiLocal = args.contains("--ai-local")
let transformArgs: [String]? = args.firstIndex(of: "--transform").map { Array(args[($0 + 1)...].prefix(2)) }
let styleArg: String? = args.firstIndex(of: "--style").map { args[$0 + 1] }
let proofreadArg: String? = args.firstIndex(of: "--proofread").map { args[$0 + 1] }
let leftArg: String? = args.firstIndex(of: "--left").map { args[$0 + 1] }
/// --track-left: 確定した文字列（insertText）を左文脈の後ろに足していく（実際の文書のように。既定は --left のまま変えない）
let trackLeft = args.contains("--track-left")
var currentLeft = leftArg
let idleArg: String? = args.firstIndex(of: "--idle").map { args[$0 + 1] }
let responsePath = args.firstIndex(of: "--responses").map { args[$0 + 1] }
let draftStartPath = args.firstIndex(of: "--draft-start").map { args[$0 + 1] }
let draftArg: String? = args.firstIndex(of: "--draft").map { args[$0 + 1] }
let sceneArg: String? = args.firstIndex(of: "--scene").map { args[$0 + 1] }
let personalArg: String? = args.firstIndex(of: "--personal").map { args[$0 + 1] }
let forgetArg: String? = args.firstIndex(of: "--forget").map { args[$0 + 1] }
/// 値をとるオプション（キー入力として扱わない）
let valueOptions: Set<String> = [
    "--responses", "--draft-start", "--style", "--left", "--llm-model", "--scene", "--personal", "--forget", "--get", "--set", "--export", "--observe-mode", "--preferred-mode",
]
struct ProbeResponse: Encodable {
    var phase: String
    var index: Int
    var elapsed: Double
    var response: ConverterServerResponse
}
func dumpResponse(_ response: ConverterServerResponse, phase: String, index: Int, elapsed: Double) {
    guard let responsePath else { return }
    let url = URL(fileURLWithPath: responsePath)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard var data = try? encoder.encode(ProbeResponse(phase: phase, index: index, elapsed: elapsed, response: response)) else { return }
    data.append(10)
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }
}
let keys: [String] = (transformArgs == nil && proofreadArg == nil && idleArg == nil && draftArg == nil && !args.contains("--models") && !args.contains("--llm-model") ? args : []).enumerated()
    .filter { i, a in !a.hasPrefix("--") && !(i > 0 && valueOptions.contains(args[i - 1])) }.map(\.element).flatMap { arg -> [String] in
    arg.hasPrefix("<") ? [arg] : arg.map(String.init)
}

let connection = NSXPCConnection(machServiceName: "dev.tomonari.inputmethod.Shizuku.ConverterServer")
connection.remoteObjectInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
connection.resume()
let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { print("XPC error:", $0); exit(1) }
    as! ConverterServerXPCProtocol

var sessionID = ""
proxy.openSession { sessionID = $0 }

func send(_ command: ConverterSessionCommand) -> ConverterServerResponse? {
    var result: ConverterServerResponse?
    let data = try! ConverterServerCodec.encode(.session(sessionID: sessionID, command: command))
    proxy.handleCommand(data) { data, error in
        if let error { print("server error:", error) }
        if let data { result = try? ConverterServerCodec.decodeResponse(from: data) }
    }
    return result
}

func keyEvent(_ key: String) -> KeyEventCore {
    let keyCodes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
    switch key {
    case "<BS>": return KeyEventCore(modifierFlags: [], characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", keyCode: 51)
    case "<SP>": return KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)
    case "<CR>": return KeyEventCore(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36)
    case "<TAB>": return KeyEventCore(modifierFlags: [], characters: "\t", charactersIgnoringModifiers: "\t", keyCode: 48)
    case "<SUGGEST>": return KeyEventCore(modifierFlags: [.control], characters: "\u{13}", charactersIgnoringModifiers: "s", keyCode: 1)
    case "-": return KeyEventCore(modifierFlags: [], characters: "-", charactersIgnoringModifiers: "-", keyCode: 27)
    case "4": return KeyEventCore(modifierFlags: [], characters: "4", charactersIgnoringModifiers: "4", keyCode: 21)
    case "<LEFT>": return KeyEventCore(modifierFlags: [], characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", keyCode: 123)
    case "<RIGHT>": return KeyEventCore(modifierFlags: [], characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", keyCode: 124)
    case "<DOWN>": return KeyEventCore(modifierFlags: [], characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", keyCode: 125)
    case "<UP>": return KeyEventCore(modifierFlags: [], characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", keyCode: 126)
    case "<S-LEFT>": return KeyEventCore(modifierFlags: [.shift], characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", keyCode: 123)
    case "<S-RIGHT>": return KeyEventCore(modifierFlags: [.shift], characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", keyCode: 124)
    case "<ESC>": return KeyEventCore(modifierFlags: [], characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", keyCode: 53)
    case "<F7>": return KeyEventCore(modifierFlags: [], characters: "\u{F70A}", charactersIgnoringModifiers: "\u{F70A}", keyCode: 98)
    case "1", "2", "3", "5", "6", "7", "8", "9":
        let codes: [String: UInt16] = ["1": 18, "2": 19, "3": 20, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
        return KeyEventCore(modifierFlags: [], characters: key, charactersIgnoringModifiers: key, keyCode: codes[key]!)
    default:
        // 大文字はシフト付きのキーとして送る（charactersIgnoringModifiers もシフトは反映される）
        let c = key.first!
        let flags: KeyEventCore.ModifierFlag = c.isUppercase ? [.shift] : []
        return KeyEventCore(modifierFlags: flags, characters: key, charactersIgnoringModifiers: key,
                            keyCode: keyCodes[Character(c.lowercased())] ?? 0)
    }
}

_ = send(.lifecycle(.activate))
/// 場面学習のメタ情報（--scene）
let sceneObservation: ConverterSceneObservation? = sceneArg.map { spec in
    var fields: [String: String] = [:]
    for part in spec.split(separator: ",") {
        let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { fields[kv[0]] = kv[1] }
    }
    return ConverterSceneObservation(
        bundleID: fields["app"], previousBundleID: fields["prev"], documentLength: fields["len"].flatMap { Int($0) },
        startedEmpty: fields["empty"] == "1", monospaced: fields["mono"].map { $0 == "1" },
        backspacesAfterCommit: fields["bs"].flatMap { Int($0) } ?? 0
    )
}
let upperBoundInspection = args.contains("--assistance-check") || args.contains(Config.labUpperBoundDataKey) || args.contains(Config.labUpperBoundInspectionKey)
let personalCapabilities = ConverterSettingClientCapabilities(supportedKinds: [.toggle, .selector, .textField, .number], supportedActions: [],
                                                             supportedCustomSurfaces: upperBoundInspection ? ["upperBoundInspection"] : [])
func personalSettings() -> [ConverterSettingDescriptor] {
    (send(.settings(.list(capabilities: personalCapabilities)))?.settings ?? []).filter { $0.section.hasPrefix("場面学習") }
}
// Task6の通し確認。試験用の記録のときだけ。本文や取り消し符号は出力しない。
if args.contains("--assistance-check") {
    guard let descriptor = send(.settings(.list(capabilities: personalCapabilities)))?.settings.first(where: { $0.key == Config.labUpperBoundInspectionKey }),
          case .string(let text) = descriptor.value, let data = text.data(using: .utf8),
          let inspection = try? JSONSerialization.jsonObject(with: data) as? [String: Any], inspection["usesTestStore"] as? Bool == true,
          let observation = sceneObservation, let app = observation.bundleID else { fatalError("試験用の記録と場面が必要です") }
    func taught(_ text: String) -> ConverterTeachingResult? {
        send(.completion(.teach(text: text, scene: observation, left: "", right: nil)))?.teachingResult
    }
    let first = taught("教えた手本の例です。")
    precondition(first?.count == 1)
    let removed = send(.completion(.undoTeach(token: first!.token!)))?.teachingResult?.count
    precondition(removed == 1)
    precondition(taught("token=sk-dummy-test-key-not-a-real-secret-0000")?.count == 0)
    for index in 0..<20 { precondition(taught("教えた手本の例\(index)です。")?.count == 1) }
    precondition(taught("上限を超えた手本です。")?.count == 0)
    let quotes = send(.completion(.quotes(scene: observation, left: "", right: nil)))?.quoteCandidates ?? []
    precondition(quotes.count <= 3 && quotes.allSatisfy { $0.count <= 50 && !$0.contains("教えた手本") })
    var quoteAccepted = 0
    if let firstQuote = quotes.first {
        let accepted = send(.completion(.acceptQuote(text: firstQuote)))
        precondition(accepted?.effects.count == 1 && accepted?.assistanceReceipt != nil)
        quoteAccepted = 1
    }
    let scene = PersonalScene(app: app, shape: .line, mode: .new, reply: false).key
    for _ in 0..<2 { _ = send(.completion(.assistance(event: "tab_owner", scene: scene, hash: nil, count: nil))) }
    let descriptors = send(.settings(.list(capabilities: personalCapabilities)))?.settings ?? []
    let summary = descriptors.first { $0.key == Config.personalLearningSummaryKey }
    guard case .string(let summaryText) = summary?.value else { fatalError("要約がありません") }
    precondition(summaryText.contains("教えた手本: 20 文") && summaryText.contains("Tabをアプリへ"))
    let result: [String: Int] = ["taught": 20, "undo": removed ?? 0, "secretRejected": 1, "quotaRejected": 1, "quotes": quotes.count, "quoteAccepted": quoteAccepted, "tabOwnerObservations": 2]
    let json = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print("assistance-check " + String(decoding: json, as: UTF8.self))
    proxy.closeSession(sessionID) { _ in }
    exit(0)
}
if let index = args.firstIndex(of: "--set") {
    let kv = args[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
    let value: ConverterSettingValue = kv[1] == "true" ? .bool(true) : kv[1] == "false" ? .bool(false) : Int(kv[1]).map { .int($0) } ?? .string(kv[1])
    let ok = send(.settings(.update(key: kv[0], value: value))) != nil
    print("設定 \(kv[0]) → \(value): \(ok ? "OK" : "失敗")")
}
if let index = args.firstIndex(of: "--get") {
    for setting in send(.settings(.list(capabilities: personalCapabilities)))?.settings ?? [] where setting.key.contains(args[index + 1]) {
        print("\(setting.key) = \(String(describing: setting.value))  （\(setting.title)）")
    }
}
if let personal = personalArg {
    let ok = send(.settings(.update(key: Config.PersonalLearning.key, value: .bool(personal == "on")))) != nil
    print("場面学習 → \(personal): \(ok ? "OK" : "失敗")")
}
if args.contains("--personal-reset") {
    let ok = send(.settings(.update(key: Config.personalLearningDeleteAllKey, value: .bool(true)))) != nil
    print("場面学習の記録と覚えた語を削除: \(ok ? "OK" : "失敗")")
}
if let index = args.firstIndex(of: "--export") {
    let ok = send(.settings(.update(key: Config.personalLearningExportKey, value: .string(args[index + 1])))) != nil
    print("場面学習の記録を書き出し → \(args[index + 1]): \(ok ? "OK" : "失敗")")
}
if let index = args.firstIndex(of: "--observe-mode") {
    for item in args[index + 1].split(separator: ",") {
        let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        let switched = kv[1].hasSuffix("!")
        let language: InputLanguage = kv[1].hasPrefix("english") ? .english : .japanese
        let ok = send(.lifecycle(.observeInputMode(bundleID: kv[0], language: language, switched: switched))) != nil
        print("入力モードの観測 \(kv[0]) \(language)\(switched ? "（自分で切り替えた）" : ""): \(ok ? "OK" : "失敗")")
    }
}
if let index = args.firstIndex(of: "--preferred-mode") {
    let r = send(.lifecycle(.preferredInputMode(bundleID: args[index + 1])))
    print("\(args[index + 1]) でいつも使う入力モード: \(r.map { $0.inputLanguage.map { "\($0)" } ?? "決まっていない" } ?? "応答なし")")
}
if let target = forgetArg {
    for setting in personalSettings() where setting.key.hasPrefix(Config.personalLearningWordKeyPrefix) && setting.title.contains(target) {
        let ok = send(.settings(.update(key: setting.key, value: .bool(false)))) != nil
        print("忘れる: \(setting.title): \(ok ? "OK" : "失敗")")
    }
}
if aiLocal || transformArgs != nil || proofreadArg != nil {
    _ = send(.updateConfig(ConverterSessionConfig(
        aiBackendPreference: .localLLM, openAIModelName: "", openAIEndpoint: "", openAIAPIKey: .init(""),
        includeContextInAITransform: true)))
}
if let style = styleArg {
    _ = send(.settings(.update(key: Config.MagicConversionStyle.key, value: .string(style))))
}
if let left = idleArg {
    _ = send(.settings(.update(key: Config.NextTextCompletion.key, value: .bool(true))))
    let t0 = Date()
    let r = send(.completion(.idle(leftContext: left)))
    print(String(format: "何も入力していない状態の続き予測 %.0fms: ", Date().timeIntervalSince(t0) * 1000) + "「\(r?.snapshot.nextTextCompletion ?? "")」")
}
if let index = args.firstIndex(of: "--llm-model") {
    // いい感じ変換のモデルを切り替える（設定画面と同じ経路）
    let ok = send(.settings(.update(key: Config.LocalLLMModel.key, value: .string(args[index + 1])))) != nil
    print("いい感じ変換のモデル → \(args[index + 1]): \(ok ? "OK" : "失敗")")
}
if args.contains("--models") {
    // 設定画面に出るモデルの選択肢（ConverterServer が models フォルダを調べた結果）
    let capabilities = ConverterSettingClientCapabilities(supportedKinds: [.toggle, .selector, .textField, .number], supportedActions: [], supportedCustomSurfaces: [])
    for setting in send(.settings(.list(capabilities: capabilities)))?.settings ?? [] where setting.key.contains("nextTextCompletion") || setting.key.hasSuffix(".model") {
        print("\(setting.title)  値=\(String(describing: setting.value))  有効=\(setting.isEnabled)")
        if case .selector(let options) = setting.kind {
            for option in options {
                print("  - \(option.title)  [\(option.value)]")
            }
        }
    }
}
if let left = draftArg {
    _ = send(.settings(.update(key: Config.NextTextCompletion.key, value: .bool(true))))
    var text = ""
    for i in 0..<3 {
        if i == 0, let draftStartPath { try? Data("started".utf8).write(to: URL(fileURLWithPath: draftStartPath)) }
        let t0 = Date()
        guard let sentence = send(.completion(.draft(leftContext: left + text)))?.snapshot.nextTextCompletion, !sentence.isEmpty else {
            break
        }
        print(String(format: "書き進める補完 [%d] %.0fms: ", i, Date().timeIntervalSince(t0) * 1000) + sentence.debugDescription)
        text += sentence
    }
}
if let text = proofreadArg {
    let t0 = Date()
    let r = send(.localLLM(.proofread(text: text, before: "", after: "")))
    let output = r?.localLLMResult?.text ?? ""
    print(String(format: "添削 %.0fms: ", Date().timeIntervalSince(t0) * 1000) + (r?.localLLMResult?.error ?? output))
    for h in TextDiff.hunks(from: text, to: output) {
        print("  [\(h.originalText)] → [\(h.replacement)]")
    }
}
if let t = transformArgs, t.count == 2 {
    let t0 = Date()
    let r = send(.localLLM(.transform(text: t[0], instruction: t[1], before: "", after: "")))
    print(String(format: "書き換え %.0fms: ", Date().timeIntervalSince(t0) * 1000) + (r?.localLLMResult?.text ?? "error: \(r?.localLLMResult?.error ?? "no response")"))
}
if complete {
    _ = send(.settings(.update(key: Config.NextTextCompletion.key, value: .bool(true))))
}
func printLearned() {
    for setting in personalSettings() {
        let value: String = switch setting.value {
        case .bool(let b): b ? "[on]" : "[off]"
        case .int(let i): "[\(i)]"
        case .string: ""
        default: ""
        }
        print("  \(setting.section)  \(setting.title) \(value)")
    }
}
print("session \(sessionID)  liveConversion=\(live)")
var nextBackspaces = 0
for (i, key) in keys.enumerated() {
    if key.hasPrefix("<BS="), let n = Int(key.dropFirst(4).dropLast()) {
        nextBackspaces = n
        continue
    }
    if key.hasPrefix("<WAIT="), let seconds = Double(key.dropFirst(6).dropLast()) {
        Thread.sleep(forTimeInterval: seconds)
        continue
    }
    if key == "<MARK>" {
        // 次のキーを送る直前の時刻を標準エラーに出す（解析と学習を止めるまでの時間を外から測る）
        FileHandle.standardError.write(Data(String(format: "MARK %.6f\n", Date().timeIntervalSince1970).utf8))
        continue
    }
    if key == "<SKEL>", var empty = sceneObservation {
        empty.documentLength = 0
        empty.startedEmpty = true
        let text = send(.completion(.skeleton(scene: empty)))?.snapshot.nextTextCompletion
        print("        <SKEL> 空の欄の書き出し: \(text.map { "「\($0)」" } ?? "なし")")
        continue
    }
    var scene = sceneObservation
    if nextBackspaces > 0 {
        scene?.backspacesAfterCommit = nextBackspaces
        nextBackspaces = 0
    }
    let request = ConverterKeyEventRequest(
        eventID: UInt64(i + 1), event: keyEvent(key), inputStyle: .defaultRomanToKana,
        liveConversionEnabled: live, enableDebugWindow: false, enableSuggestion: aiLocal,
        context: ConverterTextContext(leftSideContext: currentLeft), scene: scene)
    let t0 = Date()
    guard let r = send(.handleKeyEvent(request)) else { print("\(key): no response"); continue }
    let perKeyMs = Date().timeIntervalSince(t0) * 1000
    dumpResponse(r, phase: "key", index: i, elapsed: perKeyMs)
    let marked = r.snapshot.markedText.elements.map(\.content).joined()
    let window: String = switch r.snapshot.candidateWindow {
    case .hidden: "hidden"
    case .composing(let c, _): "composing[\(c.first?.text ?? "")]"
    case .selecting(let c, let s): "selecting(\(c.count), sel=\(s.map(String.init) ?? "nil"))"
    }
    print(String(format: "%6.1fms ", perKeyMs) + "\(key.padding(toLength: 5, withPad: " ", startingAt: 0)) handled=\(r.handled) state=\(r.inputState) marked=「\(marked)」 window=\(window) predict=\(r.snapshot.predictionCandidates.map(\.displayText)) effects=\(r.effects)")
    if trackLeft {
        for effect in r.effects {
            if case .insertText(let text) = effect {
                currentLeft = (currentLeft ?? "") + text
            }
        }
    }
    if r.effects.contains(.requestReplaceSuggestion) {
        let t1 = Date()
        if let s = send(.replaceSuggestion(.request(context: .init()))) {
            print(String(format: "  └ いい感じ変換 %6.0fms ", Date().timeIntervalSince(t1) * 1000) + "\(s.snapshot.replaceSuggestionCandidates.map(\.text))")
        }
    }
    if complete {
        let t1 = Date()
        if let c = send(.completion(.await(afterKeyEventID: UInt64(i + 1)))) {
            dumpResponse(c, phase: "completion", index: i, elapsed: Date().timeIntervalSince(t1) * 1000)
            let refined: String = if case .composing(let candidates, _) = c.snapshot.candidateWindow { candidates.map(\.text).joined(separator: ",") } else { "-" }
            print(String(format: "  └ 続き予測 %6.1fms ", Date().timeIntervalSince(t1) * 1000) + "window=[\(refined)] ghost=「\(c.snapshot.nextTextCompletion ?? "")」 predict=\(c.snapshot.predictionCandidates.map(\.displayText))")
        }
    }
}
_ = send(.composition(.stopComposition))
if args.contains("--skeleton"), let scene = sceneObservation {
    var empty = scene
    empty.documentLength = 0
    empty.startedEmpty = true
    let response = send(.completion(.skeleton(scene: empty)))
    if let response { dumpResponse(response, phase: "skeleton", index: 0, elapsed: 0) }
    let text = response?.snapshot.nextTextCompletion
    print("空の欄の書き出し: \(text.map { "「\($0)」" } ?? "なし")")
    if args.contains("--accept-skeleton"), let text {
        let ok = send(.completion(.idleAccepted(text: text))) != nil
        print("書き出しを Tab で入れた: \(ok ? "OK" : "失敗")")
    }
}
if args.contains("--learned") {
    print("場面学習:")
    printLearned()
}
proxy.closeSession(sessionID) { _ in }
