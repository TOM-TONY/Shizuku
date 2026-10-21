import Foundation

// MARK: - 個人化（場面学習）の「場面」（llm-ime）
//
// 文章そのものより「今どこに何を書いているか」で本人の書き方は変わる（Slack の 1 行と Mail の長文、返信と自発的な発言）。
// IME 本体が観測したメタ情報（アプリ・欄の大きさ・カーソルの位置など）から、粗い「場面」を決める。
// どれも弱い手がかり（Chromium 系のアプリは文脈を 100 字ほどしか返さない、位置に未初期化の値を返すなど）なので、
// 場面ごとのデータが薄いときは 場面 → アプリ → 全体 の順に後退して使う。

/// 場面キー: (アプリ, 欄の形, 書き方, 返信か[, 場所[, 相手の段]])。段があるときは場所なしでも空の5要素目を置く。
/// 場所は、本人がアクセシビリティを許可したときだけ付く（サイトのホスト名か、
/// 入力欄の案内文から作った短い符号）。場所があれば 場所つきの場面 → 場面 → アプリ → 全体 の順に後退する
public struct PersonalScene: Codable, Sendable, Hashable {
    /// 欄の形（入力欄にある文章の量と改行から推定する）
    public enum Shape: String, Codable, Sendable, CaseIterable {
        /// 1 行の欄（改行がなく短い。検索欄・チャットの 1 行・フォームの項目）
        case line
        /// 複数行の短い欄（改行がある、または 200 字以上）
        case short
        /// 長い文書（1500 字以上、または改行が 10 以上）
        case doc
        case code
        case md
    }

    /// 書き方
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// 空の欄から書き始めた（その欄で書き続けている間も含む）
        case new
        /// 既にある文章の末尾に書き足している
        case append
        /// 文章の途中（カーソルの右に文字がある）を書き換えている
        case edit
    }

    public var app: String
    public var shape: Shape
    public var mode: Mode
    public var reply: Bool
    /// 場所（アクセシビリティを許可したときだけ。サイトのホスト名か "ph:" ＋ 入力欄の案内文の符号）。なければ nil
    public var place: String?
    public var recipient: PersonalRecipient.Rank?

    public init(app: String, shape: Shape, mode: Mode, reply: Bool, place: String? = nil, recipient: PersonalRecipient.Rank? = nil) {
        self.app = app
        self.shape = shape
        self.mode = mode
        self.reply = reply
        self.place = place.flatMap { $0.isEmpty || $0.contains("|") ? nil : $0 }
        self.recipient = recipient
    }

    /// AI とのチャット・AI の道具への入力。キーには入れない（保存済みの場面と集計を変えない）
    public static let aiApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex", "com.google.GeminiMacOS",
        "ai.perplexity.mac",
    ]
    public static let aiHosts: Set<String> = [
        "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "aistudio.google.com",
        "perplexity.ai", "copilot.microsoft.com", "chat.deepseek.com", "grok.com",
    ]
    public var aiDirected: Bool {
        PersonalPrivacy.terminalApps.contains(app) || Self.aiApps.contains(app)
            || (place.map { Self.aiHosts.contains($0) } ?? false)
    }

    /// 保存・集計に使う文字列のキー（場所がなければ、場所を入れる前と同じ 4 つの部分）
    public var key: String {
        if let recipient { return self.baseKey + "|" + (self.place ?? "") + "|" + recipient.rawValue }
        return self.place.map { self.baseKey + "|" + $0 } ?? self.baseKey
    }

    /// 場所と段の共通の後退。末尾の追加要素を一つずつ除き、旧キーでは旧順序のまま。
    public var parent: PersonalScene? {
        if recipient != nil { return PersonalScene(app: app, shape: shape, mode: mode, reply: reply, place: place) }
        return place == nil ? nil : base
    }
    public var sceneKeys: [String] { [key] + (parent?.sceneKeys ?? []) }
    public var refinedKeys: [String] { Array(sceneKeys.dropLast()) }
    /// 段を初めて付けた時に、まだ句点まで届いていない同じ場面の文を引き継ぐ。
    public var continuationParentKey: String? { recipient == nil ? nil : parent?.key }
    public var levelKeys: [String] { sceneKeys + ["app:" + app, "global"] }
    public static func refinedKeys(of key: String) -> [String] {
        PersonalScene(key: key)?.refinedKeys ?? (key == baseKey(of: key) ? [] : [key])
    }
    public static func contains(_ key: String, at level: String) -> Bool { key == level || key.hasPrefix(level + "|") }

    /// 場所を除いた場面のキー（4 つの部分）
    public var baseKey: String {
        "\(app)|\(shape.rawValue)|\(mode.rawValue)|\(reply ? "reply" : "-")"
    }

    /// 場所を除いた場面
    public var base: PersonalScene {
        PersonalScene(app: self.app, shape: self.shape, mode: self.mode, reply: self.reply)
    }

    /// キー（場所つきでも）から、場所を除いた場面のキー
    public static func baseKey(of key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        return parts.count > 4 ? parts.prefix(4).joined(separator: "|") : key
    }

    public init?(key: String) {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard (4...6).contains(parts.count), let shape = Shape(rawValue: parts[1]), let mode = Mode(rawValue: parts[2]),
              parts.count != 6 || PersonalRecipient.Rank(rawValue: parts[5]) != nil else {
            return nil
        }
        self.init(app: parts[0], shape: shape, mode: mode, reply: parts[3] == "reply", place: parts.count >= 5 ? parts[4] : nil,
                  recipient: parts.count == 6 ? PersonalRecipient.Rank(rawValue: parts[5]) : nil)
    }

    /// 設定画面などに出す短い説明（アプリ名は呼び出し側で付ける）
    public var shapeAndModeLabel: String {
        let shapeLabel = switch shape {
        case .line: "1 行の欄"
        case .short: "短い文章"
        case .doc: "長い文書"
        case .code: "コード"
        case .md: "Markdown"
        }
        let modeLabel = switch mode {
        case .new: "新規"
        case .append: "追記"
        case .edit: "編集"
        }
        return "\(shapeLabel)・\(modeLabel)" + (reply ? "・返信" : "") + (place.map { $0.hasPrefix("ph:") ? "・入力欄 \($0.dropFirst(3))" : "・\($0)" } ?? "")
    }
}

/// IME 本体が観測し、キーイベントの要求に載せて送るメタ情報。
/// IME 本体は handle の中で既に問い合わせている値（文書の長さ・フォント・bundle ID）だけを使い、新しい問い合わせは増やさない
public struct ConverterSceneObservation: Codable, Sendable, Equatable {
    /// 入力先のアプリ（IMK クライアントの bundle ID）
    public var bundleID: String?
    /// その前に使っていたアプリ（どこから来たか）
    public var previousBundleID: String?
    /// 入力欄の文章の長さ（UTF-16。取れなければ nil）
    public var documentLength: Int?
    /// この欄で、空の状態から書き始めたか（送信後に空になったチャット欄なども含む）
    public var startedEmpty: Bool
    /// 入力位置の文字が等幅フォントか（コードやコメントの手がかり。取れなければ nil）
    public var monospaced: Bool?
    /// 直前の確定のあと、アプリに渡したバックスペースの数（確定直後の取り消し＝外れの手がかり）
    public var backspacesAfterCommit: Int

    public init(
        bundleID: String?,
        previousBundleID: String? = nil,
        documentLength: Int? = nil,
        startedEmpty: Bool = false,
        monospaced: Bool? = nil,
        backspacesAfterCommit: Int = 0
    ) {
        self.bundleID = bundleID
        self.previousBundleID = previousBundleID
        self.documentLength = documentLength
        self.startedEmpty = startedEmpty
        self.monospaced = monospaced
        self.backspacesAfterCommit = backspacesAfterCommit
    }
}

public extension PersonalScene {
    /// 観測した値と、キーイベントで運ばれた左右の文脈から場面を決める
    static func classify(
        observation: ConverterSceneObservation,
        leftContext: String?,
        rightContext: String?
    ) -> PersonalScene? {
        guard let app = observation.bundleID, !app.isEmpty else {
            return nil
        }
        let left = leftContext ?? ""
        let right = rightContext ?? ""
        let newlines = left.reduce(0) { $0 + ($1.isNewline ? 1 : 0) } + right.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
        // 文書の長さが取れないアプリ（または 0 を返すアプリ）は、運ばれた文脈の長さで代える
        let visible = left.utf16.count + right.utf16.count
        let length = max(observation.documentLength.flatMap { $0 >= 0 && $0 < 100_000_000 ? $0 : nil } ?? visible, visible)
        let shape: Shape = if length >= 1500 || newlines >= 10 {
            .doc
        } else if newlines == 0 && length < 200 {
            .line
        } else {
            .short
        }
        let mode: Mode = if right.contains(where: { !$0.isWhitespace }) {
            .edit
        } else if observation.startedEmpty || length == 0 {
            .new
        } else {
            .append
        }
        return PersonalScene(app: app, shape: shape, mode: mode, reply: Self.looksLikeReply(left: left, right: right))
    }

    /// 返信らしいか（引用の印があるか）。メールの返信は引用が下（右側）にあることが多いので両側を見る
    static func looksLikeReply(left: String, right: String) -> Bool {
        for text in [left, right] where !text.isEmpty {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.drop { $0 == " " || $0 == "\t" || $0 == "　" }
                if trimmed.hasPrefix(">") || trimmed.hasPrefix("＞") {
                    return true
                }
            }
            for marker in ["wrote:", "が書きました", "書きました：", "書きました:", "Original Message", "差出人:", "差出人：", "\nFrom:", "\nOn "] where text.contains(marker) {
                if marker == "\nOn " {
                    // 英文メールの引用の見出し（On Mon, ... wrote:）だけを見る
                    if text.contains("wrote") {
                        return true
                    }
                    continue
                }
                return true
            }
        }
        return false
    }
}

// MARK: - プライバシー（llm-ime）

public enum PersonalPrivacy {
    /// ターミナル類。AI の道具への入力を学ぶため記録はする。
    /// 秘密らしい確定は looksSecret で、パスワード入力は OS の安全入力で除かれる。画面の文脈では、今の行より前だけを参考資料にする（WindowReference.terminalBlocks）
    public static let terminalApps: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "com.raphaelamorim.rio"
    ]

    /// 既定で記録しないアプリ（パスワード管理・ログイン画面など）
    public static let defaultExcludedApps: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.systempreferences.PasswordAgent"
    ]

    /// 設定で除外したアプリ（改行またはカンマ区切りの bundle ID）
    public static func userExcludedApps(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public static func userExcludedApps() -> Set<String> {
        Self.userExcludedApps(Config.PersonalLearningExcludedApps().value)
    }

    /// 設定の除外リストを書き換える（設定画面のアプリごとのスイッチ）
    public static func setExcluded(_ excluded: Bool, app: String) {
        var apps = Self.userExcludedApps()
        if excluded {
            apps.insert(app)
        } else {
            apps.remove(app)
        }
        Config.PersonalLearningExcludedApps().value = apps.sorted().joined(separator: "\n")
    }

    public static func isExcluded(app: String) -> Bool {
        Self.excludedByTestStore(app: app, usingTestStore: PersonalLearner.isUsingTestStore)
            || defaultExcludedApps.contains(app) || userExcludedApps().contains(app)
    }

    /// 確かめ用のアプリ（xpcprobe が名乗るバンドル ID）
    public static let testAppPrefix = "dev.tomonari.xpcprobe"

    /// 確かめ用の記録の場所（LLM_IME_PERSONAL_DIR）を使っている間は、確かめ用のアプリだけを記録し、本人の入力は記録しない
    public static func excludedByTestStore(app: String, usingTestStore: Bool) -> Bool {
        usingTestStore && !app.hasPrefix(Self.testAppPrefix)
    }

    /// 英数字・記号の連続（パスワード・トークン・鍵のようなもの）を含むか。
    /// 12 字以上で英字と数字が混ざる、または 20 字以上の連続を秘密らしいとみなす
    public static func looksSecret(_ text: String) -> Bool {
        for token in asciiTokens(text) {
            let hasLetter = token.contains { $0.isLetter }
            let hasDigit = token.contains { $0.isNumber }
            if token.count >= 20 || (token.count >= 12 && hasLetter && hasDigit) {
                return true
            }
        }
        return false
    }

    /// 秘密らしい部分を「∗」に置き換える（左文脈の記録用）
    public static func scrub(_ text: String) -> String {
        var result = text
        for token in asciiTokens(text) {
            let hasLetter = token.contains { $0.isLetter }
            let hasDigit = token.contains { $0.isNumber }
            if token.count >= 20 || (token.count >= 12 && hasLetter && hasDigit) {
                result = result.replacingOccurrences(of: token, with: "∗")
            }
        }
        return result
    }

    /// かな・漢字を含まない（英字・数字・記号だけの）文字列か。英字の直接入力は記録しない
    public static func isWithoutJapanese(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F:
                true
            default:
                false
            }
        }
    }

    private static func asciiTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for c in text {
            if c.isASCII && (c.isLetter || c.isNumber || "+/=_-.~$!@#%^&*".contains(c)) {
                current.append(c)
            } else {
                if !current.isEmpty {
                    tokens.append(current)
                }
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
