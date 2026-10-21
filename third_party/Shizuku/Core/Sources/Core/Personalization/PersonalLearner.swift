import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// MARK: - 個人化（場面学習）の学習と記録（llm-ime）
//
// 確定と反応を場面つきで記録し（PersonalStore）、その場で学習を更新する。
// 学習は「読みつき自動辞書」: 変換の第 1 候補ではなかった表記を同じ場面で 2 回確定したら、その場面で読み全体が
// 一致したときに候補の先頭に置く。場面のデータが薄ければアプリ（3 回）、全体（4 回）に後退する。最も細かい段に
// 記録がある読みは、その段で決める（その場面で最近ちがう表記を選んでいれば、アプリや全体の学習を持ち込まない）。
// その前に「文脈つき選択学習」: 直前の 2 文字と読みが同じところで第 1 候補を退けて選んだ表記を、次は先頭に置く。
// どの段も、最近の選択ほど重く数えた得票で決め、交互に選んでいる表記は先頭に置かない。
//
// キー入力の処理（主スレッド）からは、メモリ上の表を読むだけにする。SQLite への書き込みは store.queue で行う。
// 主スレッドからだけ使う（ConverterServer は主スレッドで処理する）。

public final class PersonalLearner: @unchecked Sendable {
    public static let shared = PersonalLearner()

    /// 記録を置くフォルダ（既存の学習データと同じコンテナ）
    public static var directoryURL: URL {
        // 確かめ用: 環境変数 LLM_IME_PERSONAL_DIR があれば、記録をそこに置く（本人の記録に触れずに通しで試すとき。
        // 普段は設定しない。LaunchAgent にも書かない）。その間は確かめ用のアプリしか記録しない（PersonalPrivacy.isExcluded）
        if let override = Self.testStoreDirectory {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return AppGroup.applicationSupportDirectoryURL().appendingPathComponent("personal", isDirectory: true)
    }

    /// 確かめ用の記録のフォルダの名前（決まった名前。環境変数や設定からは作らない）
    public static let testStoreDirectoryName = "personal-e2e"

    /// App Group の中の、確かめ用の記録の場所（サンドボックスの ShizukuLab も読めるように、解析と学習の通しの確かめはここで行う）
    public static var groupTestStoreDirectory: URL {
        AppGroup.applicationSupportDirectoryURL().appendingPathComponent(Self.testStoreDirectoryName, isDirectory: true)
    }

    /// 本人の記録の本当の場所（環境変数によらない）
    static var realStoreDirectory: URL {
        AppGroup.applicationSupportDirectoryURL().appendingPathComponent("personal", isDirectory: true)
    }

    /// 確かめ用の記録を消してよい場所か。名前が決まった名前で、それ自体がリンクでなく、たどった先も同じ名前で、本当の記録の場所でも
    /// その親でも子でもないときだけ、消す場所を返す（そうでなければ nil。本人の記録を消すことが決して起きないように）
    static func safeTestStoreDeletionTarget(_ candidate: URL, realDirectory: URL) -> URL? {
        guard candidate.lastPathComponent == Self.testStoreDirectoryName else {
            return nil
        }
        if let type = (try? FileManager.default.attributesOfItem(atPath: candidate.path))?[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return nil
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let real = realDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.lastPathComponent == Self.testStoreDirectoryName else {
            return nil
        }
        let target = resolved.path
        let realPath = real.path
        if target == realPath || realPath.hasPrefix(target + "/") || target.hasPrefix(realPath + "/") {
            return nil
        }
        return resolved
    }

    /// 起動時（記録を開く前）に呼ぶ。確かめ用の記録の場所を使っていて LLM_IME_E2E_SEED があれば、その記録の写しで始める。
    /// 確かめ用の記録の場所を使っていなければ、App Group の中に残った確かめ用の記録を消す（通しの確かめの後片付け）
    public static func prepareTestStoreIfNeeded() {
        let fileManager = FileManager.default
        guard let directory = Self.testStoreDirectory else {
            let candidate = Self.groupTestStoreDirectory
            guard fileManager.fileExists(atPath: candidate.path) else {
                return
            }
            if let target = Self.safeTestStoreDeletionTarget(candidate, realDirectory: Self.realStoreDirectory) {
                try? fileManager.removeItem(at: target)
            } else {
                NSLog("llm-ime: skipped deleting the test store (not a safe target): %@", candidate.path)
            }
            return
        }
        guard let seed = ProcessInfo.processInfo.environment["LLM_IME_E2E_SEED"], !seed.isEmpty,
              fileManager.fileExists(atPath: seed) else {
            return
        }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(at: destination.appendingPathComponent("personal.sqlite" + suffix))
        }
        try? fileManager.copyItem(at: URL(fileURLWithPath: seed), to: destination.appendingPathComponent("personal.sqlite"))
    }

    /// 確かめ用の記録の場所（起動時の環境変数。なければ nil）
    static let testStoreDirectory: String? = ProcessInfo.processInfo.environment["LLM_IME_PERSONAL_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    public static var isUsingTestStore: Bool {
        Self.testStoreDirectory != nil
    }

    /// 記録を消した回数（全部・アプリごと）。ConverterServer のセッションが持つ本人の文の手本などを、変わったら捨てる
    public private(set) var forgetGeneration = 0
    private var offerTrust = PersonalOfferTrust()
    private var windowEffect = WindowReferenceEffect()
    private var tabOwners: [String: (count: Int, updated: Double)] = [:]
    private var taught: [PersonalTeaching.Entry] = []
    private var teachingUndo: (token: String, until: Double)?
    /// 本文は戻さず、保存した文数と短期の取り消し符号だけを返す。
    public func teach(_ text: String, scene: PersonalScene, now: Date = Date()) -> (count: Int, token: String?) {
        guard (storeURL == nil || Self.isRecording && store != nil), !PersonalPrivacy.isExcluded(app: scene.app),
              let sentences = PersonalTeaching.sentences(text),
              taught.filter({ $0.scene == scene.key }).count + sentences.count <= PersonalTeaching.sceneLimit else { return (0, nil) }
        let token = UUID().uuidString, ts = now.timeIntervalSince1970
        let entries = sentences.map { PersonalTeaching.Entry(id: UUID().uuidString, batch: token, scene: scene.key, app: scene.app, text: $0, ts: ts) }
        taught += entries; teachingUndo = (token, ts + PersonalTeaching.undoSeconds)
        for entry in entries { corpus.addTaught(scene: scene, text: entry.text, ts: ts, id: entry.id) }
        forgetGeneration += 1
        write { store in
            try store.transaction {
                for entry in entries {
                    try store.execute("INSERT INTO taught(id,batch,ts,scene,app,text,origin) VALUES(?,?,?,?,?,?,3)", [.text(entry.id),.text(entry.batch),.double(entry.ts),.text(entry.scene),.text(entry.app),.text(entry.text)])
                }
            }
        }
        return (entries.count, token)
    }
    @discardableResult public func undoTeaching(token: String, now: Date = Date()) -> Int {
        guard (storeURL == nil || Self.isRecording), let undo = teachingUndo, undo.token == token,
              now.timeIntervalSince1970 <= undo.until, now.timeIntervalSince1970 >= undo.until - PersonalTeaching.undoSeconds else { return 0 }
        let removed = taught.filter { $0.batch == token }
        taught.removeAll { $0.batch == token }; teachingUndo = nil
        corpus.removeTaught(ids: Set(removed.map(\.id))); forgetGeneration += 1
        write { store in
            try store.execute("DELETE FROM taught WHERE batch=?", [.text(token)])
            try store.eraseFreedPages()
        }
        return removed.count
    }
    public func teachingSummary() -> String {
        let groups = Dictionary(grouping: taught, by: \.scene)
        return "教えた手本: \(taught.count) 文" + groups.keys.sorted().map { "\n\($0): \(groups[$0]?.count ?? 0) 文" }.joined()
    }

    public func tabOwnedByApplication(scene: PersonalScene, now: Date = Date()) -> Bool {
        guard let value = tabOwners[scene.baseKey], value.count >= 2 else { return false }
        let days = Config.PersonalLearningRetentionDays().value
        return days <= 0 || value.updated >= now.timeIntervalSince1970 - Double(days) * 86400
    }
    public func recordTabOwner(scene: PersonalScene, now: Date = Date()) {
        guard self.storeURL == nil || Self.isRecording, !PersonalPrivacy.isExcluded(app: scene.app) else { return }
        let prior = tabOwners[scene.baseKey]
        let days = Config.PersonalLearningRetentionDays().value
        let fresh = prior.map { days <= 0 || $0.updated >= now.timeIntervalSince1970 - Double(days) * 86400 } ?? false
        let count = min(2, (fresh ? prior?.count ?? 0 : 0) + 1)
        tabOwners[scene.baseKey] = (count, now.timeIntervalSince1970)
        recordReaction(kind: "tab_owner", scene: scene.base, n: count, now: now)
    }
    public func tabOwnerSummary() -> String {
        let rows = tabOwners.keys.sorted().compactMap { key -> String? in
            guard let scene = PersonalScene(key: key), tabOwnedByApplication(scene: scene) else { return nil }
            return "\(key): Tabをアプリへ（観測2回）"
        }
        return "Tabの持ち主: \(rows.count) 場面" + (rows.isEmpty ? "" : "\n" + rows.joined(separator: "\n"))
    }
    public var hasOfferHistory: Bool { commitCount > 0 || offerTrust.hasEvidence }

    public func allowAutomaticOffer(_ kind: OfferKind, scene: PersonalScene, now: Date = Date()) -> Bool {
        offerTrust.allow(.init(scene: scene.baseKey, kind: kind), now: now.timeIntervalSince1970)
    }
    public func windowEffectSummary(now: Date = Date()) -> String { windowEffect.summary(now: now.timeIntervalSince1970) }
    public func offerTrustSummary(now: Date = Date()) -> String {
        let rows = offerTrust.muted(now: now.timeIntervalSince1970)
        return (["自動の助けを控える場面×種類 \(rows.count) 件（60日・Wilson95%下限<0.05、shown≥20）"] + rows.map {
            "\($0.0.scene) \($0.0.kind.rawValue): 採用\($0.1.accepted)/表示\($0.1.shown)、下限\(String(format: "%.4f", $0.1.lowerBound))（10回に1回は表示）"
        }).joined(separator: "\n")
    }
    public var onRetentionPruned: ((Double) -> Void)?

    /// 段のキー（場面のキー、"app:<バンドル ID>"、"global"）が、そのアプリのものか
    public static func level(_ level: String, belongsTo app: String) -> Bool {
        level == "app:" + app || level.hasPrefix(app + "|")
    }

    /// 移行の確認は数だけ。照合キーや salt は画面へ返さない。
    public func rewritePrivacySummary() -> String {
        guard let store else { return "" }
        var migrated = 0, scrubbed = 0, hashed = 0, total = 0
        store.queue.sync {
            migrated = (try? PersonalRewritePrivacy.meta(PersonalRewritePrivacy.migratedRowsKey, store: store)).flatMap(Int.init) ?? 0
            scrubbed = (try? PersonalRewritePrivacy.meta(PersonalRewritePrivacy.scrubbedLeftKey, store: store)).flatMap(Int.init) ?? 0
            total = Int((try? store.scalarInt("SELECT COUNT(*) FROM rewrites")) ?? 0)
            hashed = Int((try? store.scalarInt("SELECT COUNT(*) FROM rewrites WHERE length(deleted)=64 AND deleted NOT GLOB '*[^0-9a-f]*'")) ?? 0)
        }
        return "言い直しの保護: ハッシュ \(hashed)/\(total) 件・旧行の移行 \(migrated) 件・左文脈の置換 \(scrubbed) 件"
    }

    /// 言い直しの記録の数（設定画面の表示用）
    public var rewriteCount: Int {
        self.rewriteTallies.values.reduce(0) { total, byDeleted in
            total + byDeleted.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        }
    }

    /// 段ごとの登録に必要な確定回数（場面・アプリ・全体）
    nonisolated(unsafe) public static var sceneThreshold = 2
    public static let appThreshold = 3
    public static let globalThreshold = 4
    /// 先頭に置く（読み全体が一致する）読みの最短
    public static let preferenceMinimumReadingLength = 2
    /// 先頭に置く候補を作るときの重み（ユーザー辞書の語と同じ）
    public static let dictionaryValue: PValue = -5

    public enum Level: String, Sendable {
        /// 直前の文字（左文脈の末尾 2 文字）と読みが同じところ（文脈つき選択学習）
        case context
        case scene
        case app
        case global
    }

    /// 今の場面で使う学習した表記
    public struct Entry: Sendable, Equatable {
        /// 読み（カタカナ）
        public var reading: String
        public var surface: String
        public var lcid: Int
        public var rcid: Int
        public var mid: Int
        public var level: Level
        public var count: Int
    }

    /// 確定の記録（ConverterServer が場面と入力の統計を付けて渡す）
    public struct CommitRecord: Sendable {
        public var scene: PersonalScene
        public var fromApp: String?
        public var monospaced: Bool?
        public var kind: String
        /// 読み（カタカナ。わからなければ nil）
        public var reading: String?
        public var surface: String
        /// 同じ読みの範囲の、変換の第 1 候補（確定したものと同じこともある。わからなければ nil）
        public var defaultSurface: String?
        public var rank: Int?
        public var depth: Int?
        public var leftContext: String
        public var composeMilliseconds: Int?
        public var keys: Int
        public var backspaces: Int
        public var composition: Int64
        public var lcid: Int?
        public var rcid: Int?
        public var mid: Int?

        public init(
            scene: PersonalScene, fromApp: String? = nil, monospaced: Bool? = nil, kind: String, reading: String?, surface: String,
            defaultSurface: String?, rank: Int? = nil, depth: Int? = nil, leftContext: String = "", composeMilliseconds: Int? = nil,
            keys: Int = 0, backspaces: Int = 0, composition: Int64 = 0, lcid: Int? = nil, rcid: Int? = nil, mid: Int? = nil
        ) {
            self.scene = scene
            self.fromApp = fromApp
            self.monospaced = monospaced
            self.kind = kind
            self.reading = reading
            self.surface = surface
            self.defaultSurface = defaultSurface
            self.rank = rank
            self.depth = depth
            self.leftContext = leftContext
            self.composeMilliseconds = composeMilliseconds
            self.keys = keys
            self.backspaces = backspaces
            self.composition = composition
            self.lcid = lcid
            self.rcid = rcid
            self.mid = mid
        }

        /// 第 1 候補と違う表記を選んだか（第 1 候補がわからなければ選んでいない扱い）
        public var isNonDefault: Bool {
            guard let defaultSurface else {
                return false
            }
            return defaultSurface != self.surface
        }
    }

    struct LexiconKey: Hashable {
        var scene: String
        var reading: String
        var surface: String
    }

    struct LexiconRow: Sendable, Equatable {
        var scene: String
        var app: String
        var reading: String
        var surface: String
        var lcid: Int
        var rcid: Int
        var mid: Int
        var count: Int
        var nondefault: Int
        var last: Double
        /// 最近の選択ほど重い得票（同じ読みでほかの表記を選ぶたびに choiceDecay 倍に減る）
        var score: Double = 0
    }

    /// 同じ読みで選ぶたびに、それまでの得票を何倍にするか（最近の選択ほど重く）
    nonisolated(unsafe) public static var choiceDecay: Double = 0.7
    /// 場面・アプリ・全体の段で先頭に置くには、得票が 2 番目の表記の何倍以上必要か（交互に選んでいる表記は先頭に置かない）。
    nonisolated(unsafe) public static var promotionMargin: Double = 3.0
    /// 文脈の段の得票の差（同じ文脈で 1 回退けて選べば先頭に置き、次に第 1 候補を選べばやめる）
    nonisolated(unsafe) public static var contextPromotionMargin: Double = 2.0
    /// 評価用: 場面・アプリ・全体の段を使わない（文脈の段だけを見る）
    nonisolated(unsafe) public static var useSceneLevels = true

    /// 得票の多い表記が、回数・第 1 候補を退けた回数・2 番目との差を満たすか
    static func winner<Value>(
        _ surfaces: [String: Value], score: (Value) -> Double, count: (Value) -> Int, nondefault: (Value) -> Int, threshold: Int, margin: Double
    ) -> (String, Value)? {
        let ranked = surfaces.sorted { score($0.value) > score($1.value) }
        guard let top = ranked.first, count(top.value) >= threshold, nondefault(top.value) >= 1 else {
            return nil
        }
        let second = ranked.dropFirst().first.map { score($0.value) } ?? 0
        guard score(top.value) >= margin * second, score(top.value) > 0 else {
            return nil
        }
        return (top.key, top.value)
    }

    /// 文脈つき選択学習の段の、登録に必要な確定回数（その文脈で第 1 候補を退けて選んだ表記）
    nonisolated(unsafe) public static var contextThreshold = 1

    struct ContextKey: Hashable {
        var context: String
        var reading: String
    }

    /// 文脈つき選択学習: (直前の 2 文字, 読み) → 表記ごとの記録
    private(set) var contextLexicon: [ContextKey: [String: LexiconRow]] = [:]

    /// 左文脈から文脈の手がかり（空白を除いた末尾 2 文字。欄の先頭なら "^"）
    public static func contextKey(_ left: String) -> String {
        let trimmed = left.filter { !$0.isWhitespace }
        return trimmed.isEmpty ? "^" : String(trimmed.suffix(2))
    }

    private let storeURL: URL?
    private var store: PersonalStore?
    private var preparing = false
    private var rewriteSalt: String?
    private func rewriteKey(_ text: String) -> String? {
        self.rewriteSalt.map { PersonalRewritePrivacy.key(text, salt: $0) }
    }
    /// 学習した語（メモリ上の写し。起動時に読み込む）
    private(set) var lexicon: [LexiconKey: LexiconRow] = [:]
    /// 読み → その読みの記録（場面・表記）
    private var keysByReading: [String: Set<LexiconKey>] = [:]
    /// 読み → 場面 → 先頭に置く表記（読みの記録が変わったら消す）
    private var entryCache: [String: [String: Entry?]] = [:]
    private var nextCommitID: Int64 = 1
    private var nextCompositionID: Int64 = 1
    private var lastMaintenance: Date = .distantPast
    /// 記録した数（設定画面の表示用。起動時に数える）
    public private(set) var commitCount = 0
    /// 本人がこれまでに書いた文（続き予測の手本を選ぶ）
    public private(set) var corpus = PersonalCorpus()
    private var originByID: [Int64: Int] = [:]
    private var originRevision = 0
    private var originRefreshing = false
    private var lastOriginCheck = Date.distantPast
    public private(set) var stylePlans: [String: PersonalStylePlan] = [:]
    /// store.queueだけで観測を更新する。主スレッドへ渡すPlanは準備済みで本文を持たない。
    private var queuedStyleProfile = PersonalStyleProfile()
    private var queuedStylePlans: [String: PersonalStylePlan] = [:]
    /// 続き予測の手本の選び方（評価で決める）
    nonisolated(unsafe) public static var completionPrefixStyle: PersonalCorpus.PrefixStyle = .retrieve
    /// 本人の打ち間違いの癖: 「押した文字＋直した文字」（1 文字ずつ）→ 回数
    private(set) var typoPairCounts: [String: Int] = [:]
    /// 「もしかして」の訂正先の読み（カタカナ）ごとの、使った・使わなかった回数
    private(set) var typoOutcomes: [String: (accepted: Int, ignored: Int)] = [:]
    /// ず/づ の置き換え: 入力どおりの読み（カタカナ）ごとの、置き換えで確定した・置き換えを退けた回数
    private(set) var kanaVariantOutcomes: [String: (accepted: Int, rejected: Int)] = [:]
    /// アプリごとの入力モードの得票（場面に合わせた入力モード）
    public private(set) var inputModeVotes: [String: PersonalInputMode.Votes] = [:]
    /// 段（場面・アプリ・全体）ごとの、何も入力していないときに手を止めた長さ（迷いの検知）
    public private(set) var pauseHistograms: [String: PersonalRhythm.Histogram] = [:]
    public private(set) var stallIntervals: [String: PersonalRhythm.Histogram] = [:]
    private var dirtyPauseLevels: Set<String> = []
    private var lastPauseFlush = Date.distantPast
    /// 言い直し: 場面 → 消した語句 → 書き直した語句 → 回数と読み
    public private(set) var rewriteTallies: [String: [String: [String: PersonalRewrite.Tally]]] = [:]
    /// 場所つきの場面だけの言い直し（場所があるときだけ。rewriteTallies は場所を除いた場面で数える）
    private var rewritePlaceTallies: [String: [String: [String: PersonalRewrite.Tally]]] = [:]
    private var rewritePlaceIgnores: [String: Int] = [:]
    /// 言い直しを出して使われなかった回数（場面＋タブ＋消した語句）
    private var rewriteIgnores: [String: Int] = [:]
    /// 書き出し（空の欄の最初の文）: 場面 → 書き出し → 回数
    public private(set) var openingTallies: [String: [String: Int]] = [:]
    /// 場所つきの場面だけの書き出し（openingTallies は場所を除いた場面で数える）
    private var openingPlaceTallies: [String: [String: Int]] = [:]
    private var openingPlaceIgnores: [String: Int] = [:]
    /// 書き出しを出して使われなかった回数（場面ごと）
    private var openingIgnores: [String: Int] = [:]

    /// - Parameter storeURL: nil なら記録しない（テスト用にメモリだけで動かす）
    public init(storeURL: URL? = PersonalLearner.directoryURL.appendingPathComponent("personal.sqlite")) {
        self.storeURL = storeURL
        self.rewriteSalt = storeURL == nil ? PersonalRewritePrivacy.newSalt() : nil
    }

    public static var isEnabled: Bool {
        Config.PersonalLearning().value
    }

    public static var isRecording: Bool {
        Config.PersonalLearning().value && !Config.PersonalLearningPaused().value
    }

    // MARK: 準備

    /// 裏で記録を開いて、学習した語を読み込む（起動時に呼ぶ。読み込むまでは学習した語なしで動く）
    public func prepare() {
        guard let storeURL, self.store == nil, !self.preparing else {
            return
        }
        self.preparing = true
        DispatchQueue.global(qos: .utility).async {
            let store: PersonalStore?
            var rows: [LexiconRow] = []
            var contextRows: [(String, LexiconRow)] = []
            var maxCommitID: Int64 = 0
            var maxComposition: Int64 = 0
            var commits = 0
            var pairs: [String: Int] = [:]
            var texts: [(scene: String, ts: Double, text: String)] = []
            var outcomes: [String: (accepted: Int, ignored: Int)] = [:]
            var variantOutcomes: [String: (accepted: Int, rejected: Int)] = [:]
            var tuning: [String: [PersonalTuner.Knob: PersonalTuner.Setting]] = [:]
            var inputModes: [String: PersonalInputMode.Votes] = [:]
            var pauses: [String: PersonalRhythm.Histogram] = [:]
            var stallIntervals: [String: PersonalRhythm.Histogram] = [:]
            var rewrites: [String: [String: [String: PersonalRewrite.Tally]]] = [:]
            var rewriteIgnores: [String: Int] = [:]
            var openings: [String: [String: Int]] = [:]
            var origins: [Int64: Int] = [:]
            var taught: [PersonalTeaching.Entry] = []
            var styleProfile = PersonalStyleProfile()
            var openingIgnores: [String: Int] = [:]
            var offerTrust = PersonalOfferTrust()
            var windowEffect = WindowReferenceEffect()
            var tabOwners: [String: (count: Int, updated: Double)] = [:]
            do {
                let opened = try PersonalStore(url: storeURL)
                try opened.queue.sync {
                    try Self.pruneExpired(store: opened, now: Date())
                    taught = try PersonalTeaching.read(store: opened)
                    try opened.query("SELECT scene,MAX(n),MAX(ts) FROM reactions WHERE kind='tab_owner' AND scene IS NOT NULL GROUP BY scene") {
                        tabOwners[$0.text(0) ?? ""] = (Int($0.int(1)), $0.double(2))
                    }
                    try opened.query("SELECT ts,scene,kind FROM reactions WHERE ts >= ? ORDER BY ts,id", [.double(Date().timeIntervalSince1970 - PersonalOfferTrust.window)]) {
                        offerTrust.observe(reaction: $0.text(2) ?? "", scene: $0.text(1), ts: $0.double(0))
                        windowEffect.observe(reaction: $0.text(2) ?? "", ts: $0.double(0))
                    }
                    try opened.query("SELECT scene, app, reading, surface, lcid, rcid, mid, count, nondefault, last, score FROM lexicon") { row in
                        rows.append(LexiconRow(
                            scene: row.text(0) ?? "", app: row.text(1) ?? "", reading: row.text(2) ?? "", surface: row.text(3) ?? "",
                            lcid: Int(row.int(4)), rcid: Int(row.int(5)), mid: Int(row.int(6)),
                            count: Int(row.int(7)), nondefault: Int(row.int(8)), last: row.double(9), score: row.double(10)
                        ))
                    }
                    try opened.query("SELECT context, reading, surface, scene, lcid, rcid, mid, count, nondefault, last, score FROM context_lexicon") { row in
                        contextRows.append((row.text(0) ?? "", LexiconRow(
                            scene: row.text(3) ?? "", app: "", reading: row.text(1) ?? "", surface: row.text(2) ?? "",
                            lcid: Int(row.int(4)), rcid: Int(row.int(5)), mid: Int(row.int(6)),
                            count: Int(row.int(7)), nondefault: Int(row.int(8)), last: row.double(9), score: row.double(10)
                        )))
                    }
                    maxCommitID = try opened.scalarInt("SELECT MAX(id) FROM commits") ?? 0
                    maxComposition = try opened.scalarInt("SELECT MAX(composition) FROM commits") ?? 0
                    commits = Int(try opened.scalarInt("SELECT COUNT(*) FROM commits") ?? 0)
                    // 本人の文（続き予測の手本）。新しい方から最大 maxSentences 文ぶんくらい
                    try opened.query("SELECT scene, ts, surface, kind FROM commits WHERE origin IN (0,2) ORDER BY ts DESC,id DESC LIMIT 60000") { row in
                        texts.append((row.text(0) ?? "", row.double(1), row.text(2) ?? ""))
                    }
                    try opened.query("SELECT typed, fixed, COUNT(*) FROM typo_pairs WHERE length(typed) = 1 AND length(fixed) = 1 GROUP BY typed, fixed") { row in
                        pairs[(row.text(0) ?? "") + (row.text(1) ?? ""), default: 0] += Int(row.int(2))
                    }
                    try opened.query("SELECT b, kind, COUNT(*) FROM reactions WHERE kind IN ('typo_accepted', 'typo_ignored') AND b IS NOT NULL GROUP BY b, kind") { row in
                        let target = row.text(0) ?? ""
                        var outcome = outcomes[target] ?? (0, 0)
                        if row.text(1) == "typo_accepted" {
                            outcome.accepted += Int(row.int(2))
                        } else {
                            outcome.ignored += Int(row.int(2))
                        }
                        outcomes[target] = outcome
                    }
                    try opened.query("SELECT scene, deleted, written, written_reading FROM rewrites ORDER BY ts") { row in
                        let scene = row.text(0) ?? "", deleted = row.text(1) ?? "", written = row.text(2) ?? ""
                        var tally = rewrites[scene, default: [:]][deleted, default: [:]][written] ?? .init(count: 0, reading: nil)
                        tally.count += 1
                        tally.reading = row.text(3) ?? tally.reading
                        rewrites[scene, default: [:]][deleted, default: [:]][written] = tally
                    }
                    try opened.query("SELECT scene, a, COUNT(*) FROM reactions WHERE kind = 'rewrite_ignored' AND scene IS NOT NULL GROUP BY scene, a") { row in
                        rewriteIgnores[(row.text(0) ?? "") + "\t" + (row.text(1) ?? "")] = Int(row.int(2))
                    }
                    stallIntervals = try PersonalStall.intervalRows(store: opened)
                    styleProfile = try PersonalStyleProfile.read(store: opened)
                    origins = try PersonalOrigin.origins(store: opened)
                    for row in try PersonalOrigin.openings(store: opened, origins: origins) {
                        openings[row.scene, default: [:]][row.text, default: 0] += 1
                    }
                    try opened.query("SELECT scene, COUNT(*) FROM reactions WHERE kind = 'skeleton_ignored' AND scene IS NOT NULL GROUP BY scene") { row in
                        openingIgnores[row.text(0) ?? ""] = Int(row.int(1))
                    }
                    try opened.query("SELECT level, json FROM pauses") { row in
                        if let data = row.text(1)?.data(using: .utf8), let histogram = try? JSONDecoder().decode(PersonalRhythm.Histogram.self, from: data) {
                            pauses[row.text(0) ?? ""] = histogram
                        }
                    }
                    try opened.query("SELECT app, json FROM input_mode") { row in
                        if let data = row.text(1)?.data(using: .utf8), let votes = try? JSONDecoder().decode(PersonalInputMode.Votes.self, from: data) {
                            inputModes[row.text(0) ?? ""] = votes
                        }
                    }
                    try opened.query("SELECT level, knob, json FROM tuning") { row in
                        if let knob = PersonalTuner.Knob(rawValue: row.text(1) ?? ""),
                           let data = row.text(2)?.data(using: .utf8),
                           let setting = try? JSONDecoder().decode(PersonalTuner.Setting.self, from: data) {
                            tuning[row.text(0) ?? "", default: [:]][knob] = setting
                        }
                    }
                    try opened.query("SELECT b, kind, COUNT(*) FROM reactions WHERE kind IN ('kana_variant_accepted', 'kana_variant_rejected') AND b IS NOT NULL GROUP BY b, kind") { row in
                        let reading = row.text(0) ?? ""
                        var outcome = variantOutcomes[reading] ?? (0, 0)
                        if row.text(1) == "kana_variant_accepted" {
                            outcome.accepted += Int(row.int(2))
                        } else {
                            outcome.rejected += Int(row.int(2))
                        }
                        variantOutcomes[reading] = outcome
                    }
                }
                self.queuedStyleProfile = styleProfile
                store = opened
            } catch {
                NSLog("llm-ime: personal store unavailable: %@", "\(error)")
                store = nil
            }
            let stylePlans = styleProfile.plans()
            self.queuedStylePlans = stylePlans
            DispatchQueue.main.async {
                self.useStylePlans(stylePlans)
                self.store = store
                self.offerTrust = offerTrust
                self.windowEffect = windowEffect
                self.tabOwners = tabOwners
                self.taught = taught
                for entry in taught {
                    if let scene = PersonalScene(key: entry.scene) { self.corpus.addTaught(scene: scene, text: entry.text, ts: entry.ts, id: entry.id) }
                }
                self.rewriteSalt = store?.rewriteSalt
                self.stallIntervals = stallIntervals
                self.preparing = false
                self.lastMaintenance = Date()
                for row in rows {
                    self.setRow(row, for: LexiconKey(scene: row.scene, reading: row.reading, surface: row.surface))
                }
                for (context, row) in contextRows {
                    self.contextLexicon[ContextKey(context: context, reading: row.reading), default: [:]][row.surface] = row
                }
                self.nextCommitID = max(self.nextCommitID, maxCommitID + 1)
                self.nextCompositionID = max(self.nextCompositionID, maxComposition + 1)
                self.commitCount += commits
                self.originByID.merge(origins) { current, _ in current }
                self.typoPairCounts.merge(pairs, uniquingKeysWith: +)
                for text in texts.reversed() {
                    if let scene = PersonalScene(key: text.scene) {
                        self.corpus.add(scene: scene, text: text.text, ts: text.ts)
                    }
                }
                self.typoOutcomes.merge(outcomes) { ($0.accepted + $1.accepted, $0.ignored + $1.ignored) }
                self.kanaVariantOutcomes.merge(variantOutcomes) { ($0.accepted + $1.accepted, $0.rejected + $1.rejected) }
                self.inputModeVotes.merge(inputModes) { $1 }
                self.pauseHistograms.merge(pauses) { old, loaded in old.total >= loaded.total ? old : loaded }
                // 言い直し・書き出しは、場所を除いた場面で数え、場所つきの場面ならその場所でも数える
                for (scene, byDeleted) in rewrites {
                    let base = PersonalScene.baseKey(of: scene)
                    for (deleted, byWritten) in byDeleted {
                        for (written, tally) in byWritten {
                            Self.addTally(&self.rewriteTallies, scene: base, deleted: deleted, written: written, count: tally.count, reading: tally.reading)
                            for key in PersonalScene.refinedKeys(of: scene) {
                                Self.addTally(
                                    &self.rewritePlaceTallies, scene: key, deleted: deleted, written: written, count: tally.count, reading: tally.reading
                                )
                            }
                        }
                    }
                }
                for (key, count) in rewriteIgnores {
                    let scene = String(key.prefix { $0 != "\t" })
                    let base = PersonalScene.baseKey(of: scene)
                    self.rewriteIgnores[base + key.dropFirst(scene.count), default: 0] += count
                    for refined in PersonalScene.refinedKeys(of: scene) {
                        self.rewritePlaceIgnores[refined + key.dropFirst(scene.count), default: 0] += count
                    }
                }
                for (scene, texts) in openings {
                    let base = PersonalScene.baseKey(of: scene)
                    self.openingTallies[base, default: [:]].merge(texts, uniquingKeysWith: +)
                    for key in PersonalScene.refinedKeys(of: scene) {
                        self.openingPlaceTallies[key, default: [:]].merge(texts, uniquingKeysWith: +)
                    }
                }
                for (scene, count) in openingIgnores {
                    let base = PersonalScene.baseKey(of: scene)
                    self.openingIgnores[base, default: 0] += count
                    for key in PersonalScene.refinedKeys(of: scene) {
                        self.openingPlaceIgnores[key, default: 0] += count
                    }
                }
                // 自己調整の値（保存は記録と同じ SQLite に）
                PersonalTuner.shared.attach(settings: tuning) { [weak self] level, knob, setting in
                    let json = setting.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
                    self?.write { store in
                        if let json {
                            try store.execute(
                                "INSERT INTO tuning(level, knob, json) VALUES(?, ?, ?) ON CONFLICT(level, knob) DO UPDATE SET json=excluded.json",
                                [.text(level), .text(knob.rawValue), .text(json)]
                            )
                        } else {
                            try store.execute("DELETE FROM tuning WHERE level = ? AND knob = ?", [.text(level), .text(knob.rawValue)])
                        }
                    }
                }
            }
        }
    }

    /// 記録の写しを作る（解析と学習用。記録のキューで作り、終わったら主スレッドで知らせる。記録を開いていなければ false）
    public func snapshot(to url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let store else {
            Task { @MainActor in
                completion(false)
            }
            return
        }
        store.queue.async {
            let ok = (try? store.snapshot(to: url)) != nil
            Task { @MainActor in
                completion(ok)
            }
        }
    }

    /// 解析と学習に使える確定の数（答え合わせ用の直近 2 週間と、案を選ぶ用のその前の 2 週間。変換の答え合わせに使えるものだけ）
    public func labDataCounts() -> (heldOut: Int, validation: Int, lastCommit: Double?) {
        guard let store else {
            return (0, 0, nil)
        }
        var result: (Int, Int, Double?) = (0, 0, nil)
        store.queue.sync {
            guard let last = try? store.scalarDouble("SELECT MAX(ts) FROM commits") else {
                return
            }
            let split = last - LabSplit.heldOutDays * 86400
            let condition = "reading IS NOT NULL AND kind IN ('selection', 'enter', 'transform')"
            let held = (try? store.scalarInt("SELECT COUNT(*) FROM commits WHERE ts >= ? AND \(condition)", [.double(split)])) ?? 0
            let validation = (try? store.scalarInt(
                "SELECT COUNT(*) FROM commits WHERE ts >= ? AND ts < ? AND \(condition)", [.double(split - LabSplit.heldOutDays * 86400), .double(split)]
            )) ?? 0
            result = (Int(held ?? 0), Int(validation ?? 0), last)
        }
        return result
    }

    /// テスト用: 開いた記録をそのまま使う（prepare の裏の読み込みを待たない）
    func attachStoreForTesting(_ store: PersonalStore) {
        self.store = store
        self.rewriteSalt = store.rewriteSalt
    }

    /// 書き込みを裏のキューに積む（記録を開いていなければ捨てる）
    private func write(_ body: @escaping @Sendable (PersonalStore) throws -> Void) {
        guard let store else {
            return
        }
        store.queue.async {
            do {
                try body(store)
            } catch {
                NSLog("llm-ime: personal store write failed: %@", "\(error)")
            }
        }
    }

    /// メモリにたまった集計も保存して、書き込みが終わるのを待つ（停止・書き出し用）
    public func flush() {
        self.flushPauses()
        self.store?.queue.sync {}
    }

    public func makeCompositionID() -> Int64 {
        defer {
            self.nextCompositionID += 1
        }
        return self.nextCompositionID
    }

    // MARK: 変換で使う（キー入力の処理から呼ぶ。メモリだけを読む）

    /// 記録を 1 件入れる・消す（読みごとの索引と計算結果も直す）
    private func setRow(_ row: LexiconRow?, for key: LexiconKey) {
        self.lexicon[key] = row
        if row == nil {
            self.keysByReading[key.reading]?.remove(key)
            if self.keysByReading[key.reading]?.isEmpty ?? false {
                self.keysByReading[key.reading] = nil
            }
        } else {
            self.keysByReading[key.reading, default: []].insert(key)
        }
        self.entryCache[key.reading] = nil
    }

    /// 先頭に置く表記の計算をやり直す（しきい値を変えたとき）
    public func invalidateEntryCache() {
        self.entryCache.removeAll()
    }

    private func removeAllRows() {
        self.lexicon.removeAll()
        self.keysByReading.removeAll()
        self.entryCache.removeAll()
    }

    /// 読み全体（カタカナ）について、今の場面で本人が選ぶ表記。左文脈を渡すと、同じ文脈で選んだ記録を先に見る
    /// （その文脈の得票で決まる表記が第 1 候補を退けたものなら、それ。第 1 候補が抜けていれば、何もしない）
    public func preferredEntry(forReading reading: String, scene: PersonalScene, leftContext: String? = nil) -> Entry? {
        guard reading.count >= Self.preferenceMinimumReadingLength else {
            return nil
        }
        if let leftContext, let surfaces = self.contextLexicon[ContextKey(context: Self.contextKey(leftContext), reading: reading)],
           !surfaces.isEmpty {
            guard let (surface, row) = Self.winner(
                surfaces, score: \.score, count: \.count, nondefault: \.nondefault, threshold: Self.contextThreshold,
                margin: Self.contextPromotionMargin
            ) else {
                return nil
            }
            return Entry(reading: reading, surface: surface, lcid: row.lcid, rcid: row.rcid, mid: row.mid, level: .context, count: row.count)
        }
        guard Self.useSceneLevels, self.keysByReading[reading] != nil else {
            return nil
        }
        if let cached = self.entryCache[reading]?[scene.key] {
            return cached
        }
        let entry = self.sceneLevelEntry(forReading: reading, scene: scene)
        self.entryCache[reading, default: [:]][scene.key] = .some(entry)
        return entry
    }

    /// 場面 → アプリ → 全体の順に、記録のある最も細かい段の得票で決める（その読みの記録だけを集計する）
    func sceneLevelEntry(forReading reading: String, scene: PersonalScene) -> Entry? {
        struct Aggregate {
            var count = 0
            var nondefault = 0
            var last: Double = 0
            var score: Double = 0
            var lcid = 0
            var rcid = 0
            var mid = 0
        }
        var levels: [Level: [String: Aggregate]] = [:]
        // 場所つきの場面（場所があるときだけ）。その段だけで決まれば使い、決まらなければ場所を除いた場面から
        var refinedLevels: [String: [String: Aggregate]] = [:]
        let base = scene.baseKey
        // 足す順を決めておく（Set の順はプロセスごとに変わり、得票の和の最後の桁が変わりうる。答え合わせを毎回同じにするため）
        let keys = (self.keysByReading[reading] ?? []).sorted { ($0.scene, $0.surface) < ($1.scene, $1.surface) }
        for key in keys {
            guard let row = self.lexicon[key] else {
                continue
            }
            var targets: [Level] = [.global]
            if row.app == scene.app {
                targets.append(.app)
                // 場面の段は場所を除いて数える（場所つきで確定したものも含む。場所がなくても今までと同じ速さで覚える）
                if row.scene == base || PersonalScene.baseKey(of: row.scene) == base {
                    targets.append(.scene)
                }
                for key in scene.refinedKeys where PersonalScene.contains(row.scene, at: key) {
                    var aggregate = refinedLevels[key, default: [:]][row.surface, default: Aggregate()]
                    aggregate.count += row.count
                    aggregate.nondefault += row.nondefault
                    aggregate.score += row.score
                    if row.last >= aggregate.last {
                        aggregate.last = row.last
                        aggregate.lcid = row.lcid
                        aggregate.rcid = row.rcid
                        aggregate.mid = row.mid
                    }
                    refinedLevels[key, default: [:]][row.surface] = aggregate
                }
            }
            for level in targets {
                var aggregate = levels[level, default: [:]][row.surface, default: Aggregate()]
                aggregate.count += row.count
                aggregate.nondefault += row.nondefault
                aggregate.score += row.score
                if row.last >= aggregate.last {
                    aggregate.last = row.last
                    aggregate.lcid = row.lcid
                    aggregate.rcid = row.rcid
                    aggregate.mid = row.mid
                }
                levels[level, default: [:]][row.surface] = aggregate
            }
        }
        for key in scene.refinedKeys {
            if let surfaces = refinedLevels[key], let (surface, aggregate) = Self.winner(
                surfaces, score: \.score, count: \.count, nondefault: \.nondefault, threshold: Self.sceneThreshold, margin: Self.promotionMargin
            ) {
                return Entry(reading: reading, surface: surface, lcid: aggregate.lcid, rcid: aggregate.rcid, mid: aggregate.mid,
                             level: .scene, count: aggregate.count)
            }
        }
        for (level, threshold) in [(Level.scene, Self.sceneThreshold), (.app, Self.appThreshold), (.global, Self.globalThreshold)] {
            guard let surfaces = levels[level], !surfaces.isEmpty else {
                continue
            }
            guard let (surface, aggregate) = Self.winner(
                surfaces, score: \.score, count: \.count, nondefault: \.nondefault, threshold: threshold, margin: Self.promotionMargin
            ) else {
                return nil
            }
            return Entry(
                reading: reading, surface: surface, lcid: aggregate.lcid, rcid: aggregate.rcid, mid: aggregate.mid,
                level: level, count: aggregate.count
            )
        }
        return nil
    }

    // MARK: 記録（主スレッドで呼ぶ。書き込みは裏で）

    /// 確定を記録し、自動辞書を更新する。記録しなかった（除外・秘密らしい・英字だけ）なら nil
    @discardableResult
    public func recordCommit(_ record: CommitRecord, now: Date = Date(), updatingLexicon: Bool = true, origin: Int? = nil) -> Int64? {
        guard self.storeURL == nil || Self.isRecording else { return nil }
        guard !PersonalPrivacy.isExcluded(app: record.scene.app),
              !record.surface.isEmpty,
              !PersonalPrivacy.isWithoutJapanese(record.surface),
              !PersonalPrivacy.looksSecret(record.surface) else {
            return nil
        }
        let id = self.nextCommitID
        self.nextCommitID += 1
        self.commitCount += 1
        let origin = origin ?? PersonalOrigin.initial(kind: record.kind)
        self.originByID[id] = origin
        self.originRevision += 1
        if PersonalOrigin.isMaterial(origin) { self.corpus.add(scene: record.scene, text: record.surface, ts: now.timeIntervalSince1970) }
        let checkPromotion = now.timeIntervalSince(self.lastOriginCheck) >= 60
        if checkPromotion { self.lastOriginCheck = now }
        let ts = now.timeIntervalSince1970
        let left = PersonalPrivacy.scrub(String(record.leftContext.suffix(20)))
        let scene = record.scene
        let first: String? = record.isNonDefault ? record.defaultSurface : nil
        let styleGeneration = self.forgetGeneration
        self.write { store in
            let left = try PersonalRewritePrivacy.scrubRecordedLeft(left, store: store)
            try store.execute(
                """
                INSERT INTO commits(id, ts, composition, scene, app, shape, mode, reply, from_app, mono, kind, reading, surface, first, rank, depth, left, compose_ms, keys, backspaces, origin)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int(id), .double(ts), .int(record.composition), .text(scene.key), .text(scene.app), .text(scene.shape.rawValue),
                    .text(scene.mode.rawValue), .int(scene.reply ? 1 : 0), .optionalText(record.fromApp),
                    record.monospaced.map { .int($0 ? 1 : 0) } ?? .null, .text(record.kind), .optionalText(record.reading),
                    .text(record.surface), .optionalText(first), .optionalInt(record.rank), .optionalInt(record.depth), .text(left),
                    .optionalInt(record.composeMilliseconds), .int(Int64(record.keys)), .int(Int64(record.backspaces)), .int(Int64(origin))
                ]
            )
        }
        if PersonalOrigin.isMaterial(origin), PersonalOrigin.normalKinds.contains(record.kind) {
            self.write { _ in
                self.queuedStyleProfile.observe(scene: scene, text: record.surface)
                let plans = self.queuedStyleProfile.plans(reusing: self.queuedStylePlans)
                self.queuedStylePlans = plans
                DispatchQueue.main.async {
                    if styleGeneration == self.forgetGeneration { self.useStylePlans(plans) }
                }
            }
        }
        if checkPromotion {
            self.write { store in
                if try PersonalOrigin.promote(store: store) {
                    DispatchQueue.main.async { self.refreshOriginMaterial() }
                }
            }
        }
        if updatingLexicon {
            self.updateLexicon(with: record, ts: ts)
        }
        self.maintainIfNeeded(now: now)
        return id
    }

    /// 自動辞書: 第 1 候補でなかった表記の確定、または既に記録のある読みの確定を数える
    public func updateLexicon(with record: CommitRecord, ts: Double) {
        guard !PersonalPrivacy.isExcluded(app: record.scene.app), let reading = record.reading, reading.count >= Self.preferenceMinimumReadingLength,
              record.kind != "kana", record.kind != "idle", record.kind != "ai" else {
            return
        }
        self.updateContextLexicon(with: record, reading: reading, ts: ts)
        let readingHasRows = self.keysByReading[reading] != nil
        guard record.isNonDefault || readingHasRows else {
            return
        }
        // 同じ場面・読みのほかの表記の得票を減らす（最近の選択ほど重く）
        var decayed: [LexiconRow] = []
        for otherKey in self.keysByReading[reading] ?? [] where otherKey.scene == record.scene.key && otherKey.surface != record.surface {
            guard var updated = self.lexicon[otherKey] else {
                continue
            }
            updated.score *= Self.choiceDecay
            self.setRow(updated, for: otherKey)
            decayed.append(updated)
        }
        let key = LexiconKey(scene: record.scene.key, reading: reading, surface: record.surface)
        var row = self.lexicon[key] ?? LexiconRow(
            scene: record.scene.key, app: record.scene.app, reading: reading, surface: record.surface,
            lcid: record.lcid ?? CIDData.固有名詞.cid, rcid: record.rcid ?? CIDData.固有名詞.cid, mid: record.mid ?? MIDData.一般.mid,
            count: 0, nondefault: 0, last: ts
        )
        row.count += 1
        row.nondefault += record.isNonDefault ? 1 : 0
        row.last = ts
        row.score = row.score * Self.choiceDecay + 1
        if let lcid = record.lcid, let rcid = record.rcid, let mid = record.mid {
            row.lcid = lcid
            row.rcid = rcid
            row.mid = mid
        }
        self.setRow(row, for: key)
        let saved = [row] + decayed
        self.write { store in
            for row in saved {
                try store.execute(
                    """
                    INSERT INTO lexicon(scene, app, reading, surface, lcid, rcid, mid, count, nondefault, last, score) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(scene, reading, surface) DO UPDATE SET lcid=excluded.lcid, rcid=excluded.rcid, mid=excluded.mid,
                    count=excluded.count, nondefault=excluded.nondefault, last=excluded.last, score=excluded.score
                    """,
                    [
                        .text(row.scene), .text(row.app), .text(row.reading), .text(row.surface), .int(Int64(row.lcid)),
                        .int(Int64(row.rcid)), .int(Int64(row.mid)), .int(Int64(row.count)), .int(Int64(row.nondefault)), .double(row.last),
                        .double(row.score)
                    ]
                )
            }
        }
    }

    /// 文脈つき選択学習: その文脈で第 1 候補を退けて選んだ、または既に記録のある (文脈, 読み) の確定を数える
    func updateContextLexicon(with record: CommitRecord, reading: String, ts: Double) {
        let key = ContextKey(context: Self.contextKey(record.leftContext), reading: reading)
        guard record.isNonDefault || self.contextLexicon[key] != nil else {
            return
        }
        var row = self.contextLexicon[key]?[record.surface] ?? LexiconRow(
            scene: record.scene.key, app: record.scene.app, reading: reading, surface: record.surface,
            lcid: record.lcid ?? CIDData.固有名詞.cid, rcid: record.rcid ?? CIDData.固有名詞.cid, mid: record.mid ?? MIDData.一般.mid,
            count: 0, nondefault: 0, last: ts
        )
        row.count += 1
        row.nondefault += record.isNonDefault ? 1 : 0
        row.last = ts
        row.scene = record.scene.key
        row.score = row.score * Self.choiceDecay + 1
        var saved = [row]
        for (surface, other) in self.contextLexicon[key] ?? [:] where surface != record.surface {
            var updated = other
            updated.score *= Self.choiceDecay
            self.contextLexicon[key]?[surface] = updated
            saved.append(updated)
        }
        self.contextLexicon[key, default: [:]][record.surface] = row
        let context = key.context
        let rows = saved
        self.write { store in
            for row in rows {
                try store.execute(
                    """
                    INSERT INTO context_lexicon(context, reading, surface, scene, lcid, rcid, mid, count, nondefault, last, score)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(context, reading, surface) DO UPDATE SET scene=excluded.scene, count=excluded.count,
                    nondefault=excluded.nondefault, last=excluded.last, score=excluded.score
                    """,
                    [
                        .text(context), .text(row.reading), .text(row.surface), .text(row.scene), .int(Int64(row.lcid)),
                        .int(Int64(row.rcid)), .int(Int64(row.mid)), .int(Int64(row.count)), .int(Int64(row.nondefault)), .double(row.last),
                        .double(row.score)
                    ]
                )
            }
        }
    }

    /// 反応（確定直後の取り消し、続き予測・「もしかして」の採否など）を記録する
    public func recordReaction(kind: String, scene: PersonalScene?, commitID: Int64? = nil, a: String? = nil, b: String? = nil, n: Int? = nil, now: Date = Date()) {
        guard self.storeURL == nil || Self.isRecording else { return }
        if let scene, PersonalPrivacy.isExcluded(app: scene.app) {
            return
        }
        if let a, PersonalPrivacy.looksSecret(a) {
            return
        }
        let ts = now.timeIntervalSince1970
        let a = ["rewrite_accepted", "rewrite_ignored"].contains(kind) ? a.flatMap { self.rewriteKey($0) } : a
        self.offerTrust.observe(reaction: kind, scene: scene?.key, ts: ts)
        self.windowEffect.observe(reaction: kind, ts: ts)
        self.write { store in
            try store.execute(
                "INSERT INTO reactions(ts, scene, app, commit_id, kind, a, b, n) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    .double(ts), .optionalText(scene?.key), .optionalText(scene?.app), commitID.map { .int($0) } ?? .null, .text(kind),
                    .optionalText(a.map { String($0.prefix(400)) }), .optionalText(b), .optionalInt(n)
                ]
            )
            if let commitID, try PersonalOrigin.acceptEdit(store: store, id: commitID, reaction: kind, n: n, now: ts) {
                DispatchQueue.main.async { self.refreshOriginMaterial() }
            }
        }
    }

    /// 入力中の打ち直しから得た（押した打鍵、直した打鍵）の対を記録する
    public func recordTypoPair(typed: String, fixed: String, reading: String?, scene: PersonalScene?, now: Date = Date()) {
        guard typed != fixed, !typed.isEmpty, !fixed.isEmpty, typed.count <= 8, fixed.count <= 8 else {
            return
        }
        if let scene, PersonalPrivacy.isExcluded(app: scene.app) {
            return
        }
        if typed.count == 1, fixed.count == 1 {
            self.typoPairCounts[typed + fixed, default: 0] += 1
        }
        let ts = now.timeIntervalSince1970
        self.write { store in
            try store.execute(
                "INSERT INTO typo_pairs(ts, scene, app, typed, fixed, reading) VALUES(?, ?, ?, ?, ?, ?)",
                [.double(ts), .optionalText(scene?.key), .optionalText(scene?.app), .text(typed), .text(fixed), .optionalText(reading)]
            )
        }
    }

    /// 未確定中の間隔。既存の放置の分布や待ち時間とは別の表に置く。
    public func recordStallInterval(scene: PersonalScene, seconds: Double, now: Double) {
        guard Self.isRecording, !PersonalPrivacy.isExcluded(app: scene.app), seconds >= 0.1, seconds <= 60 else { return }
        for level in scene.levelKeys {
            var histogram = self.stallIntervals[level] ?? .init()
            PersonalRhythm.add(&histogram, seconds: seconds, now: now)
            self.stallIntervals[level] = histogram
            let json = String(decoding: (try? JSONEncoder().encode(histogram)) ?? Data(), as: UTF8.self)
            self.write { store in try store.execute("INSERT OR REPLACE INTO stall_intervals(level,json) VALUES(?,?)", [.text(level), .text(json)]) }
        }
    }
    public func recordStall(_ record: PersonalStall.Record) {
        guard Self.isRecording, !PersonalPrivacy.isExcluded(app: record.scene.app) else { return }
        self.write { store in try PersonalStall.insert(record, store: store) }
    }
    public func finishStallInterval(id: String, seconds: Double) {
        guard Self.isRecording, seconds.isFinite, seconds >= 0 else { return }
        self.write { store in try store.execute("UPDATE stalls SET seconds=? WHERE id=? AND event='a'", [.double(seconds), .text(id)]) }
    }
    public func annotateStall(id: String, hid: PersonalStall.HID? = nil, label: PersonalStall.Label) {
        guard Self.isRecording else { return }
        self.write { store in
            if let hid {
                try store.execute("UPDATE stalls SET hid_mouse=?,hid_scroll=?,hid_click=? WHERE id=?",
                    [hid.mouse.map { .int(Int64($0)) } ?? .null, hid.scroll.map { .int(Int64($0)) } ?? .null,
                     hid.click.map { .int(Int64($0)) } ?? .null, .text(id)])
            }
            try store.execute("UPDATE stalls SET weak_label=? WHERE id=? AND weak_label=0", [.int(Int64(label.rawValue)), .text(id)])
        }
    }
    public func linkStalls(_ ids: [String], commitID: Int64, now: Double) {
        guard Self.isRecording else { return }
        self.write { store in
            for id in ids {
                try store.execute("UPDATE stalls SET commit_id=? WHERE id=? AND commit_id IS NULL AND ts<=? AND ts>=?",
                                  [.int(commitID), .text(id), .double(now), .double(now - 120)])
            }
        }
    }
    public func recordBurst(scene: PersonalScene, characters: Int, now: Double) {
        guard Self.isRecording, !PersonalPrivacy.isExcluded(app: scene.app), characters > 0 else { return }
        self.write { store in
            var histogram = PersonalStall.Burst()
            try store.query("SELECT json FROM stall_bursts WHERE scene=?", [.text(scene.key)]) {
                if let data = $0.text(0)?.data(using: .utf8), let previous = try? JSONDecoder().decode(PersonalStall.Burst.self, from: data) { histogram = previous }
            }
            histogram.add(characters)
            let json = String(decoding: try JSONEncoder().encode(histogram), as: UTF8.self)
            try store.execute("INSERT OR REPLACE INTO stall_bursts(scene,app,ts,json) VALUES(?,?,?,?)",
                              [.text(scene.key), .text(scene.app), .double(now), .text(json)])
        }
    }
    public func recordResourceUsage(feature: String, device: String, milliseconds: Double) {
        guard Self.isRecording else { return }
        guard milliseconds.isFinite, milliseconds >= 0,
              ["ANE", "GPU"].contains(device),
              ["completion", "idle", "idle-sentence", "replay", "magic", "rewrite", "proofread", "local-llm", "lora", "analysis"].contains(feature) else { return }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        recordReaction(kind: "resource_ms", scene: nil, a: day + ":" + device, b: feature,
                       n: Int(min(1_000_000_000, milliseconds.rounded())))
    }
    public func resourceUsageSummary() -> String {
        guard let store = self.store else { return "" }
        var lines: [String] = []
        store.queue.sync {
            try? store.query("SELECT a,b,SUM(n) FROM reactions WHERE kind='resource_ms' GROUP BY a,b ORDER BY a,b") {
                lines.append("推論API時間 \($0.text(0) ?? "") \($0.text(1) ?? "") \($0.int(2)) ms")
            }
        }
        return lines.isEmpty ? "推論API時間 0 ms" : lines.joined(separator: "\n")
    }

    public func microphoneMuteSummary() -> String {
        guard let store else { return "" }
        var lines: [String] = []
        store.queue.sync {
            try? store.query("SELECT scene,kind,COUNT(*) FROM reactions WHERE kind IN ('completion_muted_mic','idle_muted_mic','skeleton_muted_mic') GROUP BY scene,kind ORDER BY scene,kind") {
                lines.append("マイクで停止 \($0.text(0) ?? "") \($0.text(1) ?? "") \($0.int(2)) 回")
            }
        }
        return lines.isEmpty ? "マイクで停止 0 回" : lines.joined(separator: "\n")
    }
    public func stallSummary() -> String {
        guard let store else { return "" }
        var events: [String: Int] = [:], labels: [Int: Int] = [:], positions: [Int: [Double]] = [:]
        var bursts: [(String, Double)] = []
        store.queue.sync {
            try? store.query("SELECT event,COUNT(*) FROM stalls GROUP BY event") { events[$0.text(0) ?? ""] = Int($0.int(1)) }
            try? store.query("SELECT weak_label,COUNT(*) FROM stalls GROUP BY weak_label") { labels[Int($0.int(0))] = Int($0.int(1)) }
            try? store.query("SELECT position,seconds FROM stalls WHERE seconds IS NOT NULL ORDER BY seconds") { positions[Int($0.int(0)), default: []].append($0.double(1)) }
            try? store.query("SELECT scene,json FROM stall_bursts ORDER BY scene") {
                if let data = $0.text(1)?.data(using: .utf8), let h = try? JSONDecoder().decode(PersonalStall.Burst.self, from: data) { bursts.append(($0.text(0) ?? "", h.median)) }
            }
        }
        var lines = ["止まりの台帳 " + PersonalStall.Event.allCases.map { "\($0.rawValue):\(events[$0.rawValue] ?? 0)" }.joined(separator: "／"),
            "弱いラベル 0:不明 \(labels[0] ?? 0)／1:考えていた \(labels[1] ?? 0)／2:読んでいた \(labels[2] ?? 0)／3:離席 \(labels[3] ?? 0)"]
        lines.append("未確定中の間 \(self.stallIntervals["global"]?.total ?? 0) 回")
        for key in positions.keys.sorted() {
            let values = positions[key] ?? []
            let median = (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
            lines.append(String(format: "位置 %d の間の中央値 %.1f 秒 (%d)", key, median, values.count))
        }
        for (scene, median) in bursts { lines.append(String(format: "バースト %@ 中央値 %.1f 字", scene, median)) }
        return lines.joined(separator: "\n")
    }

    // MARK: 続き予測の手本

    /// 続き予測の文脈の前に置く、本人の文の手本（なければ空）
    public func completionPrefix(scene: PersonalScene, context: String, before: Double? = nil, queryVector: [Float]? = nil, query: String? = nil) -> String {
        self.corpus.completionPrefix(
            style: Self.completionPrefixStyle, scene: scene, query: query ?? String(context.suffix(40)), context: context, before: before,
            queryVector: queryVector
        )
    }

    // MARK: 場面に合わせた入力モード

    /// 入力欄に入ってから最初に文字を打ったときの入力モードを数える（除外したアプリ・記録の一時停止中は数えない）
    public func recordInputMode(app: String, language: InputLanguage, switched: Bool, now: Date = Date()) {
        guard Self.isRecording, !PersonalPrivacy.isExcluded(app: app) else {
            return
        }
        var votes = self.inputModeVotes[app] ?? .init()
        PersonalInputMode.add(&votes, language: language, switched: switched, now: now.timeIntervalSince1970)
        self.inputModeVotes[app] = votes
        let json = (try? JSONEncoder().encode(votes)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.write { store in
            try store.execute(
                "INSERT INTO input_mode(app, json) VALUES(?, ?) ON CONFLICT(app) DO UPDATE SET json=excluded.json", [.text(app), .text(json)]
            )
        }
    }

    /// そのアプリでいつも使う入力モード（決まらなければ nil）
    public func preferredInputMode(app: String) -> InputLanguage? {
        guard Self.isEnabled, !PersonalPrivacy.isExcluded(app: app), let votes = self.inputModeVotes[app] else {
            return nil
        }
        return PersonalInputMode.preferred(votes)
    }

    /// そのアプリの入力モードの記録を忘れる
    public func forgetInputMode(app: String) {
        self.inputModeVotes[app] = nil
        self.write { store in
            try store.execute("DELETE FROM input_mode WHERE app = ?", [.text(app)])
        }
    }

    // MARK: 打鍵のリズム・言い直し（フェーズ 4。記録だけ）

    /// 何も入力していないときに手を止めた長さを、場面・アプリ・全体の段ごとに数える（書き込みはまとめて裏で）
    public func recordPause(scene: PersonalScene, seconds: Double, now: Date = Date()) {
        guard Self.isRecording, !PersonalPrivacy.isExcluded(app: scene.app) else {
            return
        }
        let ts = now.timeIntervalSince1970
        for level in PersonalTuner.levelKeys(for: scene) {
            var histogram = self.pauseHistograms[level] ?? .init()
            if PersonalRhythm.add(&histogram, seconds: seconds, now: ts) {
                self.pauseHistograms[level] = histogram
                self.dirtyPauseLevels.insert(level)
            }
        }
        if now.timeIntervalSince(self.lastPauseFlush) > 60 {
            self.flushPauses(now: now)
        }
    }

    /// 数えた手の止め方を保存する（変わった段だけ）
    public func flushPauses(now: Date = Date()) {
        self.lastPauseFlush = now
        guard !self.dirtyPauseLevels.isEmpty else {
            return
        }
        let rows = self.dirtyPauseLevels.compactMap { level -> (String, String)? in
            guard let histogram = self.pauseHistograms[level], let data = try? JSONEncoder().encode(histogram),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return (level, json)
        }
        self.dirtyPauseLevels.removeAll()
        self.write { store in
            for (level, json) in rows {
                try store.execute(
                    "INSERT INTO pauses(level, json) VALUES(?, ?) ON CONFLICT(level) DO UPDATE SET json=excluded.json", [.text(level), .text(json)]
                )
            }
        }
    }

    /// 言い直し（確定した直後に消して、別の語句を書いた）の対を記録する。writtenReading は書いた語句の読み（カタカナ。分からなければ nil）
    public func recordRewrite(
        scene: PersonalScene, deleted: String, written: String, writtenReading: String? = nil, commitID: Int64? = nil, now: Date = Date()
    ) {
        guard Self.isRecording, !PersonalPrivacy.isExcluded(app: scene.app), PersonalRewrite.isWorthRecording(deleted: deleted, written: written), let deletedHash = self.rewriteKey(deleted) else {
            return
        }
        Self.addTally(&self.rewriteTallies, scene: scene.baseKey, deleted: deletedHash, written: written, count: 1, reading: writtenReading)
        for key in scene.refinedKeys {
            Self.addTally(&self.rewritePlaceTallies, scene: key, deleted: deletedHash, written: written, count: 1, reading: writtenReading)
        }
        let ts = now.timeIntervalSince1970
        self.write { store in
            try store.execute(
                "INSERT INTO rewrites(ts, scene, app, commit_id, deleted, written, written_reading) VALUES(?, ?, ?, ?, ?, ?, ?)",
                [
                    .double(ts), .text(scene.key), .text(scene.app), commitID.map { .int($0) } ?? .null, .text(deletedHash), .text(written),
                    .optionalText(writtenReading)
                ]
            )
            if let commitID {
                try PersonalRewritePrivacy.scrubCommit(store: store, id: commitID, hashes: [deletedHash], salt: store.rewriteSalt)
            }
        }
    }

    private static func addTally(
        _ tallies: inout [String: [String: [String: PersonalRewrite.Tally]]], scene: String, deleted: String, written: String, count: Int, reading: String?
    ) {
        var tally = tallies[scene, default: [:]][deleted, default: [:]][written] ?? .init(count: 0, reading: nil)
        tally.count += count
        tally.reading = reading ?? tally.reading
        tallies[scene, default: [:]][deleted, default: [:]][written] = tally
    }

    /// 言い直しの書いた語句の読み（場所つきの場面 → 場面）
    public func rewriteReading(scene: PersonalScene, deleted: String, written: String) -> String? {
        guard let deleted = self.rewriteKey(deleted) else { return nil }
        return scene.refinedKeys.compactMap { self.rewritePlaceTallies[$0]?[deleted]?[written]?.reading }.first
            ?? self.rewriteTallies[scene.baseKey]?[deleted]?[written]?.reading
    }

    /// 空の欄に書き始めた最初の文（書き出し）を記録する
    public func recordOpening(scene: PersonalScene, text: String, sources: [Int64] = [], now: Date = Date()) {
        guard Self.isRecording, !PersonalPrivacy.isExcluded(app: scene.app) else {
            return
        }
        self.originRevision += 1
        if PersonalOrigin.openingIsMaterial(sources, origins: self.originByID) {
            self.openingTallies[scene.baseKey, default: [:]][text, default: 0] += 1
            for key in scene.refinedKeys { self.openingPlaceTallies[key, default: [:]][text, default: 0] += 1 }
        }
        // 提案を含む書き出しは記録だけ。すべての出所が本人由来になったとき初めて材料へ入れる。
        let encoded = String(decoding: (try? JSONEncoder().encode(sources)) ?? Data("[]".utf8), as: UTF8.self)
        let ts = now.timeIntervalSince1970
        self.write { store in
            try store.execute("INSERT INTO openings(ts, scene, app, text, sources) VALUES(?, ?, ?, ?, ?)",
                              [.double(ts), .text(scene.key), .text(scene.app), .text(text), .text(encoded)])
        }
    }

    public func recordClosing(scene: PersonalScene, text: String, sources: [Int64], now: Date = Date()) {
        guard Self.isRecording, !PersonalPrivacy.isExcluded(app: scene.app),
              PersonalClosing.extract(text) == text, !sources.isEmpty,
              PersonalOrigin.openingIsMaterial(sources, origins: self.originByID) else { return }
        let encoded = String(decoding: (try? JSONEncoder().encode(sources)) ?? Data("[]".utf8), as: UTF8.self)
        self.write { store in
            try store.execute("INSERT INTO closings(ts,scene,app,text,sources) VALUES(?,?,?,?,?)",
                [.double(now.timeIntervalSince1970), .text(scene.key), .text(scene.app), .text(text), .text(encoded)])
        }
    }
    /// 本文を表示しない。起動時にも永続記録から同じ集計を読む。
    public func closingSummary() -> String {
        guard let store else { return "" }
        var lines: [String] = []
        store.queue.sync {
            try? store.query("SELECT scene,COUNT(*) FROM closings GROUP BY scene ORDER BY scene") {
                lines.append("締めの記録 \($0.text(0) ?? "") \($0.int(1)) 件")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// その場面の空の欄で出す書き出し（場面の段だけ。学習がオフ・出さなければ nil）
    public func openingSuggestion(scene: PersonalScene) -> String? {
        guard Self.isEnabled, !PersonalPrivacy.isExcluded(app: scene.app) else {
            return nil
        }
        // 場所つきの場面だけで決まればそれ、決まらなければ場所を除いた場面（今までと同じ速さで覚える）
        for key in scene.refinedKeys {
            if let text = PersonalOpening.suggestion(tallies: self.openingPlaceTallies[key], ignores: 0) { return text }
        }
        return PersonalOpening.suggestion(tallies: self.openingTallies[scene.baseKey], ignores: 0)
    }

    /// 出した書き出しが使われた・使われなかった。自動表示の可否は共通のWilson門で決める
    public func recordOpeningOutcome(scene: PersonalScene, text: String, accepted: Bool, now: Date = Date()) {
        if !accepted {
            self.openingIgnores[scene.baseKey, default: 0] += 1
            for key in scene.refinedKeys {
                self.openingPlaceIgnores[key, default: 0] += 1
            }
        }
        guard Self.isRecording else {
            return
        }
        self.recordReaction(kind: accepted ? "skeleton_accepted" : "skeleton_ignored", scene: scene, a: text, now: now)
    }

    /// 入力中の第 1 候補 firstCandidate（読み reading）に対して出す言い直し（場面の段だけ。学習がオフ・出さなければ nil）
    public func rewriteSuggestion(scene: PersonalScene, firstCandidate: String, reading: String, repeats: Int) -> String? {
        guard Self.isEnabled, let hash = self.rewriteKey(firstCandidate) else {
            return nil
        }
        // 場所つきの場面だけで決まればそれ、決まらなければ場所を除いた場面（今までと同じ速さで覚える）
        for key in scene.refinedKeys {
            if let tallies = self.rewritePlaceTallies[key]?[hash], let written = PersonalRewrite.suggestion(
                deleted: firstCandidate, tallies: tallies, ignores: 0,
                repeats: repeats, currentReading: reading
            ) { return written }
        }
        guard let tallies = self.rewriteTallies[scene.baseKey]?[hash] else {
            return nil
        }
        return PersonalRewrite.suggestion(
            deleted: firstCandidate, tallies: tallies, ignores: 0,
            repeats: repeats, currentReading: reading
        )
    }

    /// 出した言い直しが使われた・使われなかった。無視の回数だけでは止めない
    public func recordRewriteOutcome(scene: PersonalScene, deleted: String, written: String, accepted: Bool, now: Date = Date()) {
        guard let hash = self.rewriteKey(deleted) else { return }
        if !accepted {
            self.rewriteIgnores[scene.baseKey + "\t" + hash, default: 0] += 1
            for key in scene.refinedKeys {
                self.rewritePlaceIgnores[key + "\t" + hash, default: 0] += 1
            }
        }
        guard Self.isRecording else {
            return
        }
        self.recordReaction(kind: accepted ? "rewrite_accepted" : "rewrite_ignored", scene: scene, a: deleted, b: written, now: now)
    }

    // MARK: 自己調整のための集計（裏のキューで数えて待つ。キー入力の処理からは呼ばない）

    /// 期間内の、場面ごと・反応の種類ごとの回数と n（続き予測の採用なら文字数）の合計
    public func reactionTotals(since: Double, until: Double = .infinity) -> [String: [String: (count: Int, sum: Int)]] {
        guard let store else {
            return [:]
        }
        var result: [String: [String: (count: Int, sum: Int)]] = [:]
        store.queue.sync {
            try? store.query(
                "SELECT scene, kind, COUNT(*), COALESCE(SUM(n), 0) FROM reactions WHERE ts >= ? AND ts < ? AND scene IS NOT NULL GROUP BY scene, kind",
                [.double(since), .double(until.isFinite ? until : 1e15)]
            ) { row in
                result[row.text(0) ?? "", default: [:]][row.text(1) ?? ""] = (Int(row.int(2)), Int(row.int(3)))
            }
        }
        return result
    }

    /// 期間内の、場面ごとの確定の数（続き予測の機会の数）
    public func commitTotals(since: Double, until: Double = .infinity) -> [String: Int] {
        guard let store else {
            return [:]
        }
        var result: [String: Int] = [:]
        store.queue.sync {
            try? store.query(
                "SELECT scene, COUNT(*) FROM commits WHERE ts >= ? AND ts < ? GROUP BY scene",
                [.double(since), .double(until.isFinite ? until : 1e15)]
            ) { row in
                result[row.text(0) ?? ""] = Int(row.int(1))
            }
        }
        return result
    }

    /// 自己調整の再生に使う、期間内の確定（場面ごとに時刻の順。左文脈と後ろの本文は前後の確定から作る）
    public struct ReplaySample: Sendable {
        public var scene: PersonalScene
        public var ts: Double
        /// 句の途中まで打った時点の文脈（左文脈＋句の前半）
        public var context: String
        /// 正解（句の残り＋後ろに続く本文）
        public var gold: String
        /// 句を打ち始める前の左文脈（意味の近さの問いに使う。IME でも確定の後に裏で作れるもの）
        public var left = ""
    }

    public func replaySamples(since: Double, limit: Int) -> [ReplaySample] {
        guard let store else {
            return []
        }
        var rows: [(scene: String, ts: Double, surface: String)] = []
        store.queue.sync {
            try? store.query("SELECT scene, ts, surface FROM commits WHERE ts >= ? ORDER BY ts", [.double(since)]) { row in
                rows.append((row.text(0) ?? "", row.double(1), row.text(2) ?? ""))
            }
        }
        return Self.replaySamples(from: rows, limit: limit)
    }

    /// 確定の列から再生する位置を作る（句を 2 文字目〜最後の 1 文字前のどこかで切る。新しい方から limit 件）
    public static func replaySamples(from rows: [(scene: String, ts: Double, surface: String)], limit: Int) -> [ReplaySample] {
        let samples = Self.replayContexts(from: rows).compactMap { item -> ReplaySample? in
            let index = item.index
            let characters = Array(rows[index].surface)
            guard characters.count >= 3, let scene = PersonalScene(key: rows[index].scene) else { return nil }
            let cut = 2 + (index * 7919) % (characters.count - 2)
            return ReplaySample(scene: scene, ts: rows[index].ts,
                                context: item.left + String(characters[..<cut]), gold: String(characters[cut...]) + item.next, left: item.left)
        }
        return Array(samples.sorted { ($0.ts, $0.scene.key, $0.context) > ($1.ts, $1.scene.key, $1.context) }.prefix(limit))
    }

    /// 再生で共通に使う前後の確定。句の先頭の測定でも、途中の答え合わせと同じ文脈を使う。
    public static func replayContexts(from rows: [(scene: String, ts: Double, surface: String)]) -> [(index: Int, left: String, next: String)] {
        var contexts: [(index: Int, left: String, next: String)] = []
        let byScene = Dictionary(grouping: rows.indices) { rows[$0].scene }
        // 場面の順を決めておく（Dictionary の順はプロセスごとに変わる。同じ時刻の位置があっても毎回同じものを選ぶため）
        for sceneKey in byScene.keys.sorted() {
            let indices = byScene[sceneKey]!
            guard PersonalScene(key: sceneKey) != nil else {
                continue
            }
            for (position, index) in indices.enumerated() {
                var left = ""
                var last = rows[index].ts
                for previous in indices[..<position].reversed() {
                    guard last - rows[previous].ts < 600, left.count < 200 else {
                        break
                    }
                    left = rows[previous].surface + left
                    last = rows[previous].ts
                }
                var next = ""
                last = rows[index].ts
                for following in indices[(position + 1)...] {
                    guard rows[following].ts - last < 60, next.count < 40 else {
                        break
                    }
                    next += rows[following].surface
                    last = rows[following].ts
                }
                contexts.append((index, String(left.suffix(200)), next))
            }
        }
        return contexts
    }

    // MARK: 本人の打ち間違いの癖（打鍵ミス訂正で使う）

    /// 「もしかして」を出した訂正先を、使った・使わなかった（訂正先の読みはカタカナ）
    public func recordTypoOutcome(target: String, accepted: Bool) {
        var outcome = self.typoOutcomes[target] ?? (0, 0)
        if accepted {
            outcome.accepted += 1
        } else {
            outcome.ignored += 1
        }
        self.typoOutcomes[target] = outcome
    }

    /// 本人がよく押し間違えるキーの組（3 回以上）の回数。
    public func frequentTypoPairs(minimumCount: Int = 3) -> [String: Int] {
        self.typoPairCounts.filter { $0.value >= minimumCount }
    }

    /// 訂正先ごとのしきい値の調整: 使った回数だけ下げ（−0.5 ずつ、3 回まで）、使わなかった回数だけ上げる（+1.0 ずつ、3 回まで）
    public func typoMarginAdjustment(forTarget reading: String) -> Float {
        guard let outcome = self.typoOutcomes[reading] else {
            return 0
        }
        return -0.5 * Float(min(outcome.accepted, 3)) + 1.0 * Float(min(outcome.ignored, 3))
    }

    /// ず/づ の置き換えの結果を記録する（reading は入力どおりの読み、カタカナ）
    public func recordKanaVariantOutcome(reading: String, accepted: Bool, scene: PersonalScene?) {
        var outcome = self.kanaVariantOutcomes[reading] ?? (0, 0)
        if accepted {
            outcome.accepted += 1
        } else {
            outcome.rejected += 1
        }
        self.kanaVariantOutcomes[reading] = outcome
        self.recordReaction(kind: accepted ? "kana_variant_accepted" : "kana_variant_rejected", scene: scene, b: reading)
    }

    /// ず/づ の置き換えのしきい値の調整: 置き換えで確定した読みは下げ（−0.5 ずつ、2 回まで）、一度でも退けた読みでは使わない
    public func kanaVariantMarginAdjustment(forReading reading: String) -> Float {
        guard let outcome = self.kanaVariantOutcomes[reading] else {
            return 0
        }
        if outcome.rejected > outcome.accepted {
            return 100
        }
        return -0.5 * Float(min(outcome.accepted, 2))
    }

    /// 入力どおりの読みと、確定した読みが ず→づ・じ→ぢ の置き換えだけで違うか（どちらもカタカナ）
    public static func isKanaVariant(typed: String, committed: String) -> Bool {
        guard typed.count == committed.count, typed != committed else {
            return false
        }
        return zip(typed, committed).allSatisfy { a, b in
            a == b || (a == "ズ" && b == "ヅ") || (a == "ジ" && b == "ヂ")
        }
    }

    // MARK: 保持期間

    private func maintainIfNeeded(now: Date) {
        guard now.timeIntervalSince(self.lastMaintenance) > 6 * 3600 else {
            return
        }
        self.lastMaintenance = now
        let cutoff = Self.retentionCutoff(now: now)
        if let cutoff {
            self.forgetGeneration += 1
            self.stallIntervals = self.stallIntervals.filter { $0.value.updated >= cutoff }
            self.taught.removeAll { $0.ts < cutoff }
            self.corpus.remove(before: cutoff)
            self.useStylePlans([:])
            self.onRetentionPruned?(cutoff)
            for key in self.lexicon.filter({ $0.value.last < cutoff }).map(\.key) {
                self.setRow(nil, for: key)
            }
            for (key, surfaces) in self.contextLexicon {
                let kept = surfaces.filter { $0.value.last >= cutoff }
                self.contextLexicon[key] = kept.isEmpty ? nil : kept
            }
        }
        self.write { store in
            try Self.pruneExpired(store: store, now: now)
            self.queuedStyleProfile = PersonalStyleProfile()
            DispatchQueue.main.async { self.refreshOriginMaterial() }
        }
    }

    static func retentionCutoff(now: Date) -> Double? {
        let days = Config.PersonalLearningRetentionDays().value
        guard days > 0 else {
            return nil
        }
        return now.timeIntervalSince1970 - Double(days) * 86400
    }

    static func pruneExpired(store: PersonalStore, now: Date) throws {
        guard let cutoff = Self.retentionCutoff(now: now) else {
            return
        }
        for table in ["commits", "reactions", "typo_pairs", "rewrites", "openings", "closings", "taught", "stalls", "stall_bursts"] {
            try store.execute("DELETE FROM \(table) WHERE ts < ?", [.double(cutoff)])
        }
        for (level, histogram) in try PersonalStall.intervalRows(store: store) where histogram.updated < cutoff {
            try store.execute("DELETE FROM stall_intervals WHERE level=?", [.text(level)])
        }
        try store.execute("DELETE FROM lexicon WHERE last < ?", [.double(cutoff)])
        try store.execute("DELETE FROM context_lexicon WHERE last < ?", [.double(cutoff)])
    }

    private func refreshOriginMaterial() {
        guard !self.originRefreshing, self.store != nil else { return }
        self.originRefreshing = true
        let revision = self.originRevision, generation = self.forgetGeneration
        self.write { store in
            do {
                let taught = try PersonalTeaching.read(store: store)
                let origins = try PersonalOrigin.origins(store: store)
                let rows = try PersonalOrigin.entries(store: store)
                let openings = try PersonalOrigin.openings(store: store, origins: origins)
                let corpus = PersonalCorpus()
                let profile = try PersonalStyleProfile.read(store: store)
                for row in rows {
                    if let scene = PersonalScene(key: row.scene) {
                        corpus.add(scene: scene, text: row.text, ts: row.ts)
                    }
                }
                for entry in taught {
                    if let scene = PersonalScene(key: entry.scene) { corpus.addTaught(scene: scene, text: entry.text, ts: entry.ts, id: entry.id) }
                }
                self.queuedStyleProfile = profile
                let plans = profile.plans(reusing: self.queuedStylePlans)
                self.queuedStylePlans = plans
                DispatchQueue.main.async {
                    self.originRefreshing = false
                    guard revision == self.originRevision, generation == self.forgetGeneration else {
                        self.refreshOriginMaterial(); return
                    }
                    corpus.magicTopics = self.corpus.magicTopics
                    let previousCorpus = self.corpus
                    self.corpus = corpus
                    store.queue.async { withExtendedLifetime(previousCorpus) {} }
                    self.useStylePlans(plans)
                    self.originByID = origins
                    self.openingTallies = [:]; self.openingPlaceTallies = [:]
                    for row in openings {
                        let base = PersonalScene.baseKey(of: row.scene)
                        self.openingTallies[base, default: [:]][row.text, default: 0] += 1
                        for key in PersonalScene.refinedKeys(of: row.scene) { self.openingPlaceTallies[key, default: [:]][row.text, default: 0] += 1 }
                    }
                    self.forgetGeneration += 1
                }
            } catch {
                DispatchQueue.main.async { self.originRefreshing = false }
                throw error
            }
        }
    }

    /// 大きい索引や分かち書き器の解放も主スレッドから外す。
    private func useStylePlans(_ plans: [String: PersonalStylePlan]) {
        let previous = self.stylePlans
        self.stylePlans = plans
        let queue = self.store?.queue ?? DispatchQueue.global(qos: .utility)
        queue.async { withExtendedLifetime(previous) {} }
    }

    public func normalizedGeneratedText(_ text: String, scene: PersonalScene?, route: PersonalGeneratedText.Route) -> String {
        guard Self.isEnabled else { return text }
        if let scene, PersonalPrivacy.isExcluded(app: scene.app) { return text }
        let plan = PersonalStyleProfile.levels(scene).compactMap { self.stylePlans[$0] }.first
        return PersonalGeneratedText.apply(text, route: route, enabled: true, plan: plan, honorifics: !(scene?.aiDirected ?? false))
    }

    public func protectedHonorifics(scene: PersonalScene?) -> [String] {
        guard Self.isEnabled else { return [] }
        if let scene, PersonalPrivacy.isExcluded(app: scene.app) { return [] }
        let plan = PersonalStyleProfile.levels(scene).compactMap { self.stylePlans[$0] }.first
        return PersonalHonorific.protectedTerms(usage: plan?.honorificUsage ?? [:])
    }

    /// 設定用。出所の列があることと材料の割合を、本文を返さず確認する。
    public func originSummary(now: Date = Date()) -> String {
        guard Self.isEnabled, let store else { return "" }
        var totals: [Int: Int] = [:], scenes: [String: (all: Int, own: Int)] = [:]
        store.queue.sync {
            try? store.query("SELECT origin,COUNT(*) FROM commits GROUP BY origin") { totals[Int($0.int(0))] = Int($0.int(1)) }
            try? store.query("SELECT scene,origin,COUNT(*) FROM commits WHERE ts>=? GROUP BY scene,origin", [.double(now.timeIntervalSince1970 - 30 * 86400)]) {
                let key = PersonalScene.baseKey(of: $0.text(0) ?? ""), count = Int($0.int(2))
                scenes[key, default: (0, 0)].all += count
                if PersonalOrigin.isMaterial(Int($0.int(1))) { scenes[key, default: (0, 0)].own += count }
            }
        }
        var lines = ["出所 0: \(totals[0, default: 0])／1: \(totals[1, default: 0])／2: \(totals[2, default: 0])"]
        for key in scenes.keys.sorted() {
            let n = scenes[key]!
            lines.append(String(format: "本人の言葉の割合 %@ %.1f%%（%d/%d、30日）", key, 100 * Double(n.own) / Double(max(1, n.all)), n.own, n.all))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 覚えたことの表示・削除・書き出し

    public struct LearnedWord: Sendable, Equatable {
        /// 設定のキーに使う識別子（場面・読み・表記）
        public var id: String
        public var scene: PersonalScene?
        public var reading: String
        public var surface: String
        public var count: Int
    }

    /// 文脈つき選択学習で、その文脈で先頭に置く表記の数（設定画面の集計用）
    public var contextChoiceCount: Int {
        self.contextLexicon.values.filter {
            Self.winner(
                $0, score: \.score, count: \.count, nondefault: \.nondefault, threshold: Self.contextThreshold, margin: Self.contextPromotionMargin
            ) != nil
        }.count
    }

    /// 登録された語（場面ごと。回数の多い順）
    public func learnedWords(limit: Int = 100) -> [LearnedWord] {
        self.lexicon.values
            .filter { $0.count >= Self.sceneThreshold && $0.nondefault >= 1 }
            .sorted { ($0.count, $0.last) > ($1.count, $1.last) }
            .prefix(limit)
            .map {
                LearnedWord(
                    id: Self.wordID(scene: $0.scene, reading: $0.reading, surface: $0.surface),
                    scene: PersonalScene(key: $0.scene), reading: $0.reading, surface: $0.surface, count: $0.count
                )
            }
    }

    static func wordID(scene: String, reading: String, surface: String) -> String {
        Data([scene, reading, surface].joined(separator: "\u{1F}").utf8).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeWordID(_ id: String) -> (scene: String, reading: String, surface: String)? {
        var bytes: [UInt8] = []
        var index = id.startIndex
        while index < id.endIndex {
            let next = id.index(index, offsetBy: 2, limitedBy: id.endIndex) ?? id.endIndex
            guard let byte = UInt8(id[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        let parts = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{1F}")
        guard parts.count == 3 else {
            return nil
        }
        return (parts[0], parts[1], parts[2])
    }

    /// 覚えた語を忘れる（その読みと表記の記録をすべての場面から消す）
    public func forgetWord(id: String) {
        guard let (_, reading, surface) = Self.decodeWordID(id) else {
            return
        }
        for key in (self.keysByReading[reading] ?? []).filter({ $0.surface == surface }) {
            self.setRow(nil, for: key)
        }
        for key in self.contextLexicon.keys where key.reading == reading {
            self.contextLexicon[key]?[surface] = nil
            if self.contextLexicon[key]?.isEmpty ?? false {
                self.contextLexicon[key] = nil
            }
        }
        self.write { store in
            try store.execute("DELETE FROM lexicon WHERE reading = ? AND surface = ?", [.text(reading), .text(surface)])
            try store.execute("DELETE FROM context_lexicon WHERE reading = ? AND surface = ?", [.text(reading), .text(surface)])
        }
    }

    /// そのアプリの記録と学習をすべて消す（学習がオフでも、記録しないアプリにしていても消す）。
    /// メモリ上の写し（自動辞書・文脈の選択・手本の文・言い直し・手を止めた長さ・入力モード・調整した値）はこの呼び出しの中で消し、
    /// 記録（SQLite）からは裏で消して、消した文章がファイルに残らないように WAL を書き戻して VACUUM する
    public func forgetApp(_ app: String) {
        taught.removeAll { $0.app == app }; teachingUndo = nil
        self.offerTrust.forget(app: app)
        self.tabOwners = self.tabOwners.filter { PersonalScene(key: $0.key)?.app != app }
        guard !app.isEmpty else {
            return
        }
        let belongs = { (level: String) in Self.level(level, belongsTo: app) }
        for key in self.lexicon.filter({ $0.value.app == app || belongs($0.key.scene) }).map(\.key) {
            self.setRow(nil, for: key)
        }
        for (key, surfaces) in self.contextLexicon {
            let kept = surfaces.filter { !belongs($0.value.scene) }
            if kept.count != surfaces.count {
                self.contextLexicon[key] = kept.isEmpty ? nil : kept
            }
        }
        self.stallIntervals = self.stallIntervals.filter { !belongs($0.key) && $0.key != "global" }
        var intervalsGlobal = PersonalRhythm.Histogram()
        for (level, histogram) in self.stallIntervals where level.hasPrefix("app:") {
            intervalsGlobal.counts = zip(intervalsGlobal.counts, histogram.counts).map(+)
            intervalsGlobal.updated = max(intervalsGlobal.updated, histogram.updated)
        }
        intervalsGlobal.total = intervalsGlobal.counts.reduce(0, +)
        if intervalsGlobal.total > 0 { self.stallIntervals["global"] = intervalsGlobal }
        let intervalTotal = intervalsGlobal.total
        let intervalJSON = String(decoding: (try? JSONEncoder().encode(intervalsGlobal)) ?? Data(), as: UTF8.self)
        self.corpus.removeApp(app)
        self.useStylePlans([:])
        self.inputModeVotes[app] = nil
        for scene in self.rewriteTallies.keys where belongs(scene) {
            self.rewriteTallies[scene] = nil
        }
        for key in self.rewriteIgnores.keys where belongs(key) {
            self.rewriteIgnores[key] = nil
        }
        for scene in self.openingTallies.keys where belongs(scene) {
            self.openingTallies[scene] = nil
        }
        for scene in self.rewritePlaceTallies.keys where belongs(scene) {
            self.rewritePlaceTallies[scene] = nil
        }
        for key in self.rewritePlaceIgnores.keys where belongs(key) {
            self.rewritePlaceIgnores[key] = nil
        }
        for scene in self.openingPlaceTallies.keys where belongs(scene) {
            self.openingPlaceTallies[scene] = nil
        }
        for scene in self.openingPlaceIgnores.keys where belongs(scene) {
            self.openingPlaceIgnores[scene] = nil
        }
        for scene in self.openingIgnores.keys where belongs(scene) {
            self.openingIgnores[scene] = nil
        }
        // 手を止めた長さ: そのアプリの段を消し、全体の段は残ったアプリの段から作り直す
        for level in self.pauseHistograms.keys where belongs(level) {
            self.pauseHistograms[level] = nil
        }
        self.dirtyPauseLevels = self.dirtyPauseLevels.filter { !belongs($0) }
        var global = PersonalRhythm.Histogram()
        for (level, histogram) in self.pauseHistograms where level.hasPrefix("app:") && histogram.counts.count == global.counts.count {
            global.counts = zip(global.counts, histogram.counts).map(+)
            global.updated = max(global.updated, histogram.updated)
        }
        global.total = global.counts.reduce(0, +)
        self.pauseHistograms["global"] = global.total > 0 ? global : nil
        let globalJSON = global.total > 0 ? (try? JSONEncoder().encode(global)).flatMap { String(data: $0, encoding: .utf8) } : nil
        if self === PersonalLearner.shared {
            PersonalTuner.shared.forget(levels: belongs)
        }
        self.forgetGeneration += 1
        self.write { store in
            try store.transaction {
                for table in ["commits", "reactions", "typo_pairs", "lexicon", "rewrites", "input_mode", "openings", "closings", "taught", "stalls", "stall_bursts"] {
                    try store.execute("DELETE FROM \(table) WHERE app = ?", [.text(app)])
                }
                try store.execute("DELETE FROM context_lexicon WHERE substr(scene, 1, ?) = ?", [.int(Int64(app.count + 1)), .text(app + "|")])
                // 場面のない反応（自己調整の記録）は、a の段がそのアプリのもの
                var ids: [Int64] = []
                try store.query("SELECT id, a FROM reactions WHERE app IS NULL AND a IS NOT NULL") { row in
                    if let a = row.text(1), let level = a.split(separator: "@").last.map(String.init), Self.level(level, belongsTo: app) {
                        ids.append(row.int(0))
                    }
                }
                for id in ids {
                    try store.execute("DELETE FROM reactions WHERE id = ?", [.int(id)])
                }
                for table in ["pauses", "tuning", "stall_intervals"] {
                    try store.execute(
                        "DELETE FROM \(table) WHERE level = ? OR substr(level, 1, ?) = ?",
                        [.text("app:" + app), .int(Int64(app.count + 1)), .text(app + "|")]
                    )
                }
                try store.execute("DELETE FROM stall_intervals WHERE level='global'")
                if intervalTotal > 0 {
                    try store.execute("INSERT INTO stall_intervals(level,json) VALUES('global',?)", [.text(intervalJSON)])
                }
                if let globalJSON {
                    try store.execute(
                        "INSERT INTO pauses(level, json) VALUES('global', ?) ON CONFLICT(level) DO UPDATE SET json=excluded.json", [.text(globalJSON)]
                    )
                } else {
                    try store.execute("DELETE FROM pauses WHERE level = 'global'")
                }
            }
            try store.eraseFreedPages()
            self.queuedStyleProfile = PersonalStyleProfile()
            // アプリをまたいで数えている集計（打ち間違いの癖・「もしかして」・ず/づ・確定の数）は、残った記録から数え直す。
            // 消すのと同じ裏のキューで数え、主スレッドに渡す（キー入力の処理を VACUUM で待たせない）
            let counts = Self.recountAggregates(store: store)
            DispatchQueue.main.async { [weak self] in
                self?.typoPairCounts = counts.pairs
                self?.typoOutcomes = counts.outcomes
                self?.kanaVariantOutcomes = counts.variants
                self?.commitCount = counts.commits
                self?.refreshOriginMaterial()
            }
        }
    }

    /// 打ち間違いの癖・「もしかして」・ず/づ の採否・確定の数を、記録から数え直す（記録を消した後。記録のキューの上で呼ぶ）
    private static func recountAggregates(store: PersonalStore) -> (
        pairs: [String: Int], outcomes: [String: (accepted: Int, ignored: Int)], variants: [String: (accepted: Int, rejected: Int)], commits: Int
    ) {
        var pairs: [String: Int] = [:]
        var outcomes: [String: (accepted: Int, ignored: Int)] = [:]
        var variants: [String: (accepted: Int, rejected: Int)] = [:]
        var commits = 0
        do {
            try? store.query("SELECT typed, fixed, COUNT(*) FROM typo_pairs WHERE length(typed) = 1 AND length(fixed) = 1 GROUP BY typed, fixed") { row in
                pairs[(row.text(0) ?? "") + (row.text(1) ?? ""), default: 0] += Int(row.int(2))
            }
            try? store.query("SELECT b, kind, COUNT(*) FROM reactions WHERE kind IN ('typo_accepted', 'typo_ignored') AND b IS NOT NULL GROUP BY b, kind") { row in
                var outcome = outcomes[row.text(0) ?? ""] ?? (0, 0)
                if row.text(1) == "typo_accepted" {
                    outcome.accepted += Int(row.int(2))
                } else {
                    outcome.ignored += Int(row.int(2))
                }
                outcomes[row.text(0) ?? ""] = outcome
            }
            try? store.query("SELECT b, kind, COUNT(*) FROM reactions WHERE kind IN ('kana_variant_accepted', 'kana_variant_rejected') AND b IS NOT NULL GROUP BY b, kind") { row in
                var outcome = variants[row.text(0) ?? ""] ?? (0, 0)
                if row.text(1) == "kana_variant_accepted" {
                    outcome.accepted += Int(row.int(2))
                } else {
                    outcome.rejected += Int(row.int(2))
                }
                variants[row.text(0) ?? ""] = outcome
            }
            commits = Int((try? store.scalarInt("SELECT COUNT(*) FROM commits")) ?? 0)
        }
        return (pairs, outcomes, variants, commits)
    }

    /// 記録と学習をすべて消す
    public func deleteAll() {
        taught.removeAll(); teachingUndo = nil
        self.tabOwners.removeAll()
        self.offerTrust = PersonalOfferTrust()
        self.windowEffect = WindowReferenceEffect()
        let salt = PersonalRewritePrivacy.newSalt()
        self.rewriteSalt = salt
        self.forgetGeneration += 1
        self.removeAllRows()
        self.contextLexicon.removeAll()
        self.corpus.removeAll()
        self.commitCount = 0
        self.typoPairCounts.removeAll()
        self.typoOutcomes.removeAll()
        self.kanaVariantOutcomes.removeAll()
        self.inputModeVotes.removeAll()
        self.stallIntervals.removeAll()
        self.pauseHistograms.removeAll()
        self.dirtyPauseLevels.removeAll()
        self.rewriteTallies.removeAll()
        self.rewriteIgnores.removeAll()
        self.openingTallies.removeAll()
        self.openingIgnores.removeAll()
        self.rewritePlaceTallies.removeAll()
        self.rewritePlaceIgnores.removeAll()
        self.openingPlaceTallies.removeAll()
        self.openingPlaceIgnores.removeAll()
        self.useStylePlans([:])
        if self === PersonalLearner.shared {
            PersonalTuner.shared.reset()
        }
        self.write { store in
            try store.transaction {
                for table in ["commits", "reactions", "typo_pairs", "lexicon", "context_lexicon", "tuning", "input_mode", "pauses", "rewrites", "openings", "closings", "taught", "stalls", "stall_intervals", "stall_bursts"] {
                    try store.execute("DELETE FROM \(table)")
                }
                try store.resetRewriteSalt(salt)
            }
            try store.eraseFreedPages()
            self.queuedStyleProfile = PersonalStyleProfile()
            DispatchQueue.main.async { self.refreshOriginMaterial() }
        }
    }

    /// 記録のあるアプリ（確定の数の多い順。確定はなくても、反応・言い直し・入力モード・手を止めた長さなどの記録があるアプリも 0 件で含める）。
    /// 設定画面の「アプリごとの記録」（消す操作）に使う
    public func appsWithRecords(limit: Int = 50) -> [(app: String, count: Int)] {
        var result = self.appCommitCounts(limit: limit)
        var seen = Set(result.map(\.app))
        var others: Set<String> = []
        if let store {
            store.queue.sync {
                for table in ["reactions", "typo_pairs", "lexicon", "rewrites", "input_mode", "openings", "closings", "taught", "stalls", "stall_bursts"] {
                    try? store.query("SELECT DISTINCT app FROM \(table) WHERE app IS NOT NULL") { row in
                        others.insert(row.text(0) ?? "")
                    }
                }
            }
        }
        others.formUnion(self.stallIntervals.keys.filter { $0.hasPrefix("app:") }.map { String($0.dropFirst(4)) })
        others.formUnion(self.inputModeVotes.keys)
        others.formUnion(self.pauseHistograms.keys.filter { $0.hasPrefix("app:") }.map { String($0.dropFirst(4)) })
        for app in others.sorted() where !app.isEmpty && !seen.contains(app) && result.count < limit {
            result.append((app, 0))
            seen.insert(app)
        }
        return result
    }

    /// アプリごとの記録の数（多い順）。設定画面の表示用（裏のキューで数えて待つ）
    public func appCommitCounts(limit: Int = 30) -> [(app: String, count: Int)] {
        guard let store else {
            return []
        }
        var result: [(String, Int)] = []
        store.queue.sync {
            try? store.query("SELECT app, COUNT(*) AS c FROM commits GROUP BY app ORDER BY c DESC LIMIT ?", [.int(Int64(limit))]) { row in
                result.append((row.text(0) ?? "", Int(row.int(1))))
            }
        }
        return result
    }

    /// 反応の集計（続き予測・「もしかして」の採用率など。設定画面の表示用）
    public func reactionCounts() -> [String: Int] {
        guard let store else {
            return [:]
        }
        var result: [String: Int] = [:]
        store.queue.sync {
            try? store.query("SELECT kind, COUNT(*) FROM reactions GROUP BY kind") { row in
                result[row.text(0) ?? ""] = Int(row.int(1))
            }
            if let pairs = try? store.scalarInt("SELECT COUNT(*) FROM typo_pairs") {
                result["typo_pairs"] = Int(pairs)
            }
        }
        return result
    }

    /// 記録をすべて JSON Lines に書き出して、その場所を返す（destination を省くと記録と同じフォルダ）
    public func export(to destination: URL? = nil, now: Date = Date()) throws -> URL {
        guard let store else {
            throw PersonalStore.StoreError(description: "記録を開けていません")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = destination ?? store.url.deletingLastPathComponent().appendingPathComponent("export-\(formatter.string(from: now)).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines: [String] = []
        var thrown: Error?
        store.queue.sync {
            do {
                let tables: [(String, [String])] = [
                    ("commits", ["id", "ts", "composition", "scene", "app", "shape", "mode", "reply", "from_app", "mono", "kind", "reading", "surface", "first", "rank", "depth", "left", "compose_ms", "keys", "backspaces", "origin"]),
                    ("reactions", ["id", "ts", "scene", "app", "commit_id", "kind", "a", "b", "n"]),
                    ("typo_pairs", ["id", "ts", "scene", "app", "typed", "fixed", "reading"]),
                    ("rewrites", ["id", "ts", "scene", "app", "commit_id", "deleted", "written", "written_reading"]),
                    ("stalls", ["id", "ts", "scene", "app", "event", "position", "seconds", "depth", "deleted_chars", "commit_id", "weak_label", "hid_mouse", "hid_scroll", "hid_click"]),
                    ("stall_intervals", ["level", "json"]),
                    ("stall_bursts", ["scene", "app", "ts", "json"]),
                    ("pauses", ["level", "json"]),
                    ("openings", ["id", "ts", "scene", "app", "text", "sources"]),
                    ("closings", ["id", "ts", "scene", "app", "text", "sources"]),
                    ("taught", ["id", "batch", "ts", "scene", "app", "text", "origin"]),
                    ("lexicon", ["scene", "app", "reading", "surface", "lcid", "rcid", "mid", "count", "nondefault", "last"]),
                    ("context_lexicon", ["context", "reading", "surface", "scene", "count", "nondefault", "last"])
                ]
                for (table, columns) in tables {
                    try store.query("SELECT \(columns.joined(separator: ", ")) FROM \(table)") { row in
                        var object: [String: Any] = ["table": table]
                        for (index, column) in columns.enumerated() where !row.isNull(Int32(index)) {
                            object[column] = row.text(Int32(index)) ?? ""
                        }
                        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                           let line = String(data: data, encoding: .utf8) {
                            lines.append(line)
                        }
                    }
                }
            } catch {
                thrown = error
            }
        }
        if let thrown {
            throw thrown
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
