import CryptoKit
import Foundation

/// 履歴の上限を測るだけの再生。設定、学習器、版、採否の経路を持たない。
public enum LabUpperBound {
    public static let normalKinds: Set<String> = ["selection", "enter", "transform", "kana"]
    public static let stopOrder = ["oneChunk", "twoChunks", "punctuation", "sentence", "all"]
    public static let thresholds: [(String, Float)] = [("default", NextTextCompletionEngine.defaultMinLogProb),
                                                      ("-1.0", -1), ("-1.5", -1.5), ("-2.0", -2), ("none", -.infinity)]
    public struct Counter: Codable, Equatable, Sendable {
        public var count = 0
        public var totals: [String: Double] = [:]
        public var means: [String: Double] = [:]
        mutating func add(_ values: [String: Double]) {
            count += 1
            for (key, value) in values { totals[key, default: 0] += value }
        }
        mutating func finish() {
            means = totals.mapValues { count == 0 ? 0 : $0 / Double(count) }
            if let shown = totals["shown"] { means["wrongAmongShown"] = shown > 0 ? (totals["wrong"] ?? 0) / shown : 0 }
        }
    }
    public struct Group: Codable, Equatable, Sendable {
        public var position: String
        public var tier: String
        public var scope: String
        public var key: String
        public var kind: String
        public var subset: String
        public var oracle = Counter()
        public var retrieval = Counter()
        public var completion: [String: Counter] = [:]
        public var shadow: [String: [String: Counter]] = [:]
        public var stopping: [String: Counter] = [:]
        public var bestStopping: String?
    }
    public struct Inventory: Codable, Equatable, Sendable {
        public var available: Int
        public var target: Int
        public var optimisticDays: Double?
        public var basis: String
    }
    public struct SceneRow: Codable, Equatable, Sendable {
        public var scene: String
        public var commits: Int
        public var nonDefault: Int
        public var kinds: [String: Int]
        public var emptyLeft: Int
        public var rewrites: Int
        public var pauses: Int
        public var commitsPerDay: Double
        public var inventory: [String: Inventory]
    }
    public struct Auxiliary: Codable, Sendable {
        public var rewrites: [String: Int] = [:]
        public var pauses: [String: Int] = [:]
        public var phrases: [String: Int] = [:]
        public var totalRewrites = 0
        public var totalPauses = 0
        public init() {}
    }
    public struct Trace: Codable, Equatable, Sendable {
        public var index: Int
        public var position: String
        public var mode: String
        public var contextHash: String
        public var goldHash: String
        public var prefixHash: String
        public var piecesHash: String
    }
    public struct Report: Codable, Equatable, Sendable {
        public var schema = 1
        public var inputHash: String
        public var auxiliaryHash: String
        public var modelConfigurationHash: String?
        public var bm25: [String: Double]
        public var commits: Int
        public var rewrites: Int
        public var pauses: Int
        public var positions: [String: Int]
        public var completionStatus: String
        public var heldOutDays = LabSplit.heldOutDays
        public var usesHeldOutSplit = false
        public var chunkApproximation = "punctuation-or-particle-after:はがをにでともへの"
        public var inventoryApproximation = "closing=sentence-end opportunities; connective=adjacent sentence pairs within 60s; phrases=lexicon count>=3 and 4...12 chars; days=missing/commits-per-day (optimistic, not readiness)"
        public var pauseAggregation = "existing hierarchical histogram totals, including child places; may be decayed"
        public var tierAggregation = "place/scene/app/global=restricted history pools; production=actual fallback; production-*=cohort selected by that fallback"
        public var observationDays: Double
        public var groups: [Group]
        public var scenes: [SceneRow]
        public var replay: [Trace]

        public func group(position: String, tier: String, subset: String = "all") -> Group? {
            groups.first { $0.position == position && $0.tier == tier && $0.scope == "all" && $0.kind == "all" && $0.subset == subset }
        }
        public func canonicalJSON() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return try encoder.encode(self) + Data("\n".utf8)
        }
        public var summary: String {
            var lines = ["oracle は履歴から求めた上限であり、実装できる性能ではありません。"]
            for (position, label) in [("mid", "句の途中"), ("start", "句の先頭")] {
                let oracle = group(position: position, tier: "global")?.oracle
                let production = group(position: position, tier: "production")
                let e4b = production?.completion["retrieve"]
                let shadow = production?.shadow["retrieve"]
                let comparison = e4b.map { String(format: "E4B手本つき4字 %.1f%%（%d位置）", 100 * ($0.means["prefix4"] ?? 0), $0.count) } ?? "E4B列なし（\(completionStatus)）"
                lines.append(String(format: "%@ %d位置／oracle 4字 %.1f%%／", label, positions[position] ?? 0, 100 * (oracle?.means["prefix4"] ?? 0)) + comparison)
                if let matched = group(position: position, tier: "global", subset: "matched") {
                    lines.append(String(format: "同じ%d位置のoracle 4字 %.1f%%", matched.oracle.count, 100 * (matched.oracle.means["prefix4"] ?? 0)))
                }
                if let shadow {
                    lines.append("\(label) 節約文字 既定 \(Int(shadow["default"]?.totals["saved"] ?? 0))／しきい値なし \(Int(shadow["none"]?.totals["saved"] ?? 0))")
                }
            }
            let retrieval = group(position: "start", tier: "production")?.retrieval
            lines.append(String(format: "自己一致率 BM25上位1件 %.1f%%／3件 %.1f%%", 100 * (retrieval?.means["top1F1"] ?? 0), 100 * (retrieval?.means["top3F1"] ?? 0)))
            lines.append("場面別の表 \(scenes.count)行（在庫は候補機会、見込み日数は楽観的な下限）")
            return lines.joined(separator: "\n")
        }
    }
    public struct Position: Sendable {
        public var index: Int
        public var type: String
        public var scene: PersonalScene
        public var ts: Double
        public var kind: String
        public var context: String
        public var gold: String
        public var contentGold: String
        public var left: String
        public var isBody: Bool
        public var prefix = ""
        public var isCompared = false
        public var productionTier = "global"
    }
    public typealias Generator = @Sendable (_ items: [(context: String, prefix: String)]) async throws -> [[NextTextCompletionEngine.Piece]]

    /// 元の確定の番号を保ち、途中の cut・前後の文脈は既存の再生と共通にする。
    public static func positions(_ rows: [LabCommit], limit: Int = .max) -> [Position] {
        let records = rows.map { (scene: $0.scene, ts: $0.ts, surface: $0.surface) }
        let selected = Set(rows.indices.reversed().prefix(max(0, limit)))
        var result: [Position] = []
        for item in PersonalLearner.replayContexts(from: records) where selected.contains(item.index) {
            let row = rows[item.index]
            guard let scene = PersonalScene(key: row.scene), !row.surface.isEmpty else { continue }
            let body = normalKinds.contains(row.kind) && row.surface.count >= 12 && row.surface.last.map { "。！？!?\n".contains($0) } == true
            result.append(Position(index: item.index, type: "start", scene: scene, ts: row.ts, kind: row.kind,
                                   context: item.left, gold: row.surface + item.next, contentGold: row.surface, left: item.left, isBody: body))
            let chars = Array(row.surface)
            if chars.count >= 3 {
                let cut = 2 + (item.index * 7919) % (chars.count - 2)
                let gold = String(chars[cut...]) + item.next
                result.append(Position(index: item.index, type: "mid", scene: scene, ts: row.ts, kind: row.kind,
                                       context: item.left + String(chars[..<cut]), gold: gold, contentGold: gold, left: item.left, isBody: body))
            }
        }
        return result.sorted { ($0.ts, $0.index, $0.type) < ($1.ts, $1.index, $1.type) }
    }
    public static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 保護領域を外から開かずに、数値結果と片付け・採否不変を確かめるための数とハッシュ。
    public struct Inspection: Codable, Sendable {
        public var running: Bool
        public var runFiles: Int
        public var snapshots: Int
        public var protectedFiles: [String: String]
        public var resultHash: String?
        public var unreadable: Int
        public var usesTestStore = false
        public var testStoreExists = false
    }
    public static func inspection(directory: URL, running: Bool = false) -> Inspection {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var protected: [String: String] = [:]
        var runFiles = 0, snapshots = 0, unreadable = 0
        // atPathの相対名を使う。macOSではURL列挙だけ/private/varになり、根の/varと一致しないことがある。
        let entries = fm.enumerator(atPath: directory.path)
        if entries == nil, fm.fileExists(atPath: directory.path) { unreadable += 1 }
        while let relative = entries?.nextObject() as? String {
            let file = directory.appendingPathComponent(relative)
            guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { unreadable += 1; continue }
            guard info.isSymbolicLink != true, info.isRegularFile == true else { continue }
            if relative.hasPrefix("runs/") {
                runFiles += 1
                if file.lastPathComponent == "snapshot.sqlite" { snapshots += 1 }
                continue
            }
            if relative == "last-upper-bound.json" { continue }
            guard let attributes = try? fm.attributesOfItem(atPath: file.path) else { unreadable += 1; continue }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            var stamp = "\(size)|\(modified)|\(inode)"
            if size < 65536, !["sqlite", "db"].contains(file.pathExtension), !file.lastPathComponent.hasSuffix("-wal"), !file.lastPathComponent.hasSuffix("-shm") {
                if let data = try? Data(contentsOf: file) { stamp += "|" + hash(data) } else { unreadable += 1 }
            }
            protected[hash(relative)] = hash(stamp)
        }
        let result = try? Data(contentsOf: directory.appendingPathComponent("last-upper-bound.json"))
        return Inspection(running: running, runFiles: runFiles, snapshots: snapshots, protectedFiles: protected,
                          resultHash: result.map { hash($0) }, unreadable: unreadable)
    }
    public static func lcp(_ a: String, _ b: String) -> Int {
        lcp(Array(a.precomposedStringWithCompatibilityMapping), Array(b.precomposedStringWithCompatibilityMapping))
    }
    private static func lcp(_ a: [Character], _ b: [Character]) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
    /// 表層文字列だけで変換エンジンの文節を得るAPIはないため、助詞・句読点の直後で近似する。
    public static func cuts(_ text: String) -> [String: String] {
        let chars = Array(text)
        let chunks = chars.indices.filter { "、。，．,.！？!?\nはがをにでともへの".contains(chars[$0]) }.map { $0 + 1 }
        let punct = chars.firstIndex { "、。，．,.！？!?\n".contains($0) }.map { $0 + 1 } ?? chars.count
        let sentence = chars.firstIndex { "。！？!?\n".contains($0) }.map { $0 + 1 } ?? chars.count
        return ["oneChunk": String(chars.prefix(chunks.first ?? chars.count)),
                "twoChunks": String(chars.prefix(chunks.dropFirst().first ?? chars.count)),
                "punctuation": String(chars.prefix(punct)), "sentence": String(chars.prefix(sentence)), "all": text]
    }
    public static func stoppingScore(_ text: String, gold: String) -> [String: Double] {
        let prefix = lcp(text, gold)
        return ["net": Double(2 * prefix - text.precomposedStringWithCompatibilityMapping.count),
                "lcp": Double(prefix), "saved": Double(LabReplay.textOutcome(text: text, gold: gold).saved)]
    }
    private static func groupKeys(_ position: Position, tier: String) -> [Group] {
        var groups: [Group] = []
        for (scope, key) in [("all", "*"), ("app", position.scene.app), ("scene", position.scene.key)] {
            for kind in ["all", position.kind] {
                var subsets = position.isBody ? ["all", "body"] : ["all"]
                if position.isCompared { subsets += position.isBody ? ["matched", "matchedBody"] : ["matched"] }
                for subset in subsets {
                    groups.append(Group(position: position.type, tier: tier, scope: scope, key: key, kind: kind, subset: subset))
                }
            }
        }
        return groups
    }
    private static func key(_ group: Group) -> String {
        [group.position, group.tier, group.scope, group.key, group.kind, group.subset].joined(separator: "\u{1f}")
    }
    private static func belongs(_ sentence: PersonalCorpus.Sentence, tier: String, scene: PersonalScene) -> Bool {
        tier == "global" || tier == "app" && sentence.app == scene.app
            || tier == "scene" && sentence.baseScene == scene.baseKey || tier == "place" && sentence.scene == scene.key
    }
    private static func productionGroups(_ position: Position) -> [Group] {
        groupKeys(position, tier: "production") + groupKeys(position, tier: "production-" + position.productionTier)
    }
    public static func measure(
        commits input: [LabCommit], auxiliary: Auxiliary = .init(), limit: Int = .max, completionStatus: String = "no-model",
        generate: Generator? = nil, progress: @Sendable (String, Double) -> Void = { _, _ in }
    ) async throws -> Report {
        // 同時刻は入力順（写しのid順）。未来・同時刻の確定は一切索引へ足さない。
        let rows = input.enumerated().sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }.map(\.element)
        var samples = positions(rows, limit: limit)
        if generate != nil {
            for type in ["mid", "start"] {
                for index in samples.indices.filter({ samples[$0].type == type }).suffix(300) { samples[index].isCompared = true }
            }
        }
        let corpus = PersonalCorpus()
        var cursor = 0
        var groups: [String: Group] = [:]
        var fingerprints: [String: (LabMagic.Fingerprint, [Character])] = [:]
        for i in samples.indices {
            var position = samples[i]
            while cursor < rows.count, rows[cursor].ts < position.ts {
                let row = rows[cursor]
                if row.isMaterial && normalKinds.contains(row.kind), let scene = PersonalScene(key: row.scene) { corpus.add(scene: scene, text: row.surface, ts: row.ts) }
                cursor += 1
            }
            let tiers = position.scene.place == nil ? ["scene", "app", "global"] : ["place", "scene", "app", "global"]
            let chosen = corpus.retrieve(query: String(position.context.suffix(40)), scene: position.scene, excluding: position.context, before: position.ts)
            if chosen.count >= 2 {
                position.productionTier = tiers.first { tier in chosen.allSatisfy { belongs($0, tier: tier, scene: position.scene) } } ?? "global"
            }
            position.prefix = corpus.completionPrefix(style: .retrieve, scene: position.scene,
                                                       query: String(position.context.suffix(40)), context: position.context, before: position.ts)
            samples[i] = position
            var maxima = Dictionary(uniqueKeysWithValues: tiers.map { ($0, (lcp: 0, f1: 0.0, pool: 0)) })
            let gold = Array(position.gold.precomposedStringWithCompatibilityMapping)
            let content = LabMagic.Fingerprint(position.contentGold)
            for sentence in corpus.sentences where sentence.ts < position.ts {
                let cached = fingerprints[sentence.text] ?? (LabMagic.Fingerprint(sentence.text), Array(sentence.text.precomposedStringWithCompatibilityMapping))
                fingerprints[sentence.text] = cached
                let prefix = lcp(cached.1, gold), f1 = LabMagic.f1(cached.0, content)
                for tier in tiers {
                    let eligible = belongs(sentence, tier: tier, scene: position.scene)
                    if eligible {
                        var maximum = maxima[tier]!
                        maximum.lcp = max(maximum.lcp, prefix); maximum.f1 = max(maximum.f1, f1); maximum.pool += 1
                        maxima[tier] = maximum
                    }
                }
            }
            for tier in tiers {
                let maximum = maxima[tier]!
                let cohorts = tier == position.productionTier ? groupKeys(position, tier: "production-" + tier) : []
                for shape in groupKeys(position, tier: tier) + cohorts {
                    let id = key(shape)
                    var group = groups[id] ?? shape
                    group.oracle.add(["prefix2": maximum.lcp >= 2 ? 1 : 0, "prefix4": maximum.lcp >= 4 ? 1 : 0,
                                      "prefix8": maximum.lcp >= 8 ? 1 : 0, "lcp": Double(maximum.lcp), "f1": maximum.f1,
                                      "f1AtLeast07": maximum.f1 >= 0.7 ? 1 : 0, "pool": Double(maximum.pool)])
                    groups[id] = group
                }
            }
            if position.type == "start" {
                let found = corpus.retrieve(query: String(position.left.suffix(40)), scene: position.scene, excluding: position.context, limit: 3, before: position.ts)
                // 段別の比較も、全履歴に対する本番BM25の点・同点順を保つ。存在しないアプリで全体まで後退させて順位を一度だけ求める。
                let globalScene = PersonalScene(app: "", shape: .line, mode: .new, reply: false)
                let ranked = corpus.retrieve(query: String(position.left.suffix(40)), scene: globalScene, excluding: position.context, limit: .max, before: position.ts)
                var comparisons = tiers.map { tier in (groupKeys(position, tier: tier), Array(ranked.filter { belongs($0, tier: tier, scene: position.scene) }.prefix(3))) }
                comparisons.append((productionGroups(position), found))
                for (shapes, retrieved) in comparisons {
                    let top1 = retrieved.first?.text ?? ""
                    let top1F1 = retrieved.first.map { LabMagic.f1($0.text, position.contentGold) } ?? 0
                    let top3F1 = retrieved.map { LabMagic.f1($0.text, position.contentGold) }.max() ?? 0
                    for shape in shapes {
                        let id = key(shape)
                        var group = groups[id] ?? shape
                        group.retrieval.add(["top1F1": top1F1 >= 0.7 ? 1 : 0, "top3F1": top3F1 >= 0.7 ? 1 : 0,
                                             "lcp": Double(lcp(top1, position.gold)), "saved": Double(LabReplay.textOutcome(text: top1, gold: position.gold).saved),
                                             "returned": top1.isEmpty ? 0 : 1])
                        groups[id] = group
                    }
                }
            }
            if i % 20 == 0 { progress("upper-bound-oracle", Double(i + 1) / Double(max(1, samples.count))) }
        }
        var traces: [Trace] = []
        if let generate {
            var requests: [(position: Position, mode: String)] = []
            for type in ["mid", "start"] {
                let chosen = Array(samples.filter { $0.type == type }.reversed().prefix(300))
                for mode in ["retrieve", "none"] { requests += chosen.map { ($0, mode) } }
            }
            // 1回のreplayにまとめる。長いSIGSTOPの壁時計で、途中のモデル解放が再生へ混ざらないようにする。
            progress("upper-bound-e4b", 0)
            let pieces = try await generate(requests.map { ($0.position.context, $0.mode == "retrieve" ? $0.position.prefix : "") })
            guard pieces.count == requests.count else { throw LabError.invalidResult("続き予測の位置がそろわなかった") }
            for (index, pair) in zip(requests, pieces).enumerated() {
                let (request, tokens) = pair
                let position = request.position, mode = request.mode
                let ungated = tokens.map(\.text).joined()
                let suggestion = NextTextCompletionEngine.suggestion(from: tokens, threshold: NextTextCompletionEngine.defaultMinLogProb)
                traces.append(Trace(index: position.index, position: position.type, mode: mode, contextHash: hash(position.context), goldHash: hash(position.gold),
                                    prefixHash: hash(mode == "retrieve" ? position.prefix : ""), piecesHash: hash(tokens.map { "\($0.text)\u{1f}\($0.logProb)" }.joined(separator: "\u{1e}"))))
                for shape in productionGroups(position) {
                    let id = key(shape)
                    var group = groups[id] ?? shape
                    let outcome = LabReplay.completionOutcome(pieces: tokens, gold: position.gold, threshold: NextTextCompletionEngine.defaultMinLogProb)
                    var score = group.completion[mode] ?? Counter()
                    score.add(["prefix4": suggestion.map { $0.count >= 4 && position.gold.precomposedStringWithCompatibilityMapping.hasPrefix(String($0.prefix(4)).precomposedStringWithCompatibilityMapping) ? 1 : 0 } ?? 0,
                               "saved": Double(outcome.saved), "wrong": outcome.wrong ? 1 : 0,
                               "shown": suggestion == nil ? 0 : 1,
                               "hidden": suggestion == nil ? 1 : 0,
                               "hiddenLcp": suggestion == nil ? Double(lcp(ungated, position.gold)) : 0])
                    group.completion[mode] = score
                    for (name, threshold) in thresholds {
                        let outcome = LabReplay.completionOutcome(pieces: tokens, gold: position.gold, threshold: threshold)
                        let shown = NextTextCompletionEngine.suggestion(from: tokens, threshold: threshold) != nil
                        var counter = group.shadow[mode]?[name] ?? Counter()
                        counter.add(["shown": shown ? 1 : 0, "saved": Double(outcome.saved), "wrong": outcome.wrong ? 1 : 0])
                        group.shadow[mode, default: [:]][name] = counter
                    }
                    if mode == "retrieve" {
                        for (name, text) in cuts(ungated) {
                            var counter = group.stopping[name] ?? Counter()
                            counter.add(stoppingScore(text, gold: position.gold))
                            group.stopping[name] = counter
                        }
                    }
                    groups[id] = group
                }
                if index % 4 == 0 { progress("upper-bound-e4b", Double(index + 1) / Double(max(1, requests.count))) }
            }
        }
        let result = groups.keys.sorted().map { id -> Group in
            var group = groups[id]!
            group.oracle.finish(); group.retrieval.finish()
            for mode in group.completion.keys.sorted() { group.completion[mode]!.finish() }
            for mode in group.shadow.keys.sorted() {
                for threshold in group.shadow[mode]!.keys.sorted() { group.shadow[mode]![threshold]!.finish() }
            }
            for cut in group.stopping.keys.sorted() { group.stopping[cut]!.finish() }
            group.bestStopping = stopOrder.filter { (group.stopping[$0]?.count ?? 0) > 0 }.max { a, b in
                (group.stopping[a]?.means["net"] ?? 0) < (group.stopping[b]?.means["net"] ?? 0)
            }
            return group
        }
        let days = max(1, ((rows.last?.ts ?? 0) - (rows.first?.ts ?? 0)) / 86400)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Report(inputHash: hash(String(decoding: try encoder.encode(rows), as: UTF8.self)),
                      auxiliaryHash: hash(String(decoding: try encoder.encode(auxiliary), as: UTF8.self)),
                      bm25: ["k1": PersonalCorpus.bm25K1, "b": PersonalCorpus.bm25B, "budget": Double(PersonalCorpus.prefixCharacterBudget)], commits: rows.count,
                      rewrites: auxiliary.totalRewrites, pauses: auxiliary.totalPauses,
                      positions: ["mid": samples.filter { $0.type == "mid" }.count, "start": samples.filter { $0.type == "start" }.count],
                      completionStatus: completionStatus, observationDays: days, groups: result,
                      scenes: sceneTable(rows, auxiliary: auxiliary, days: days), replay: traces)
    }
    public static func sceneTable(_ rows: [LabCommit], auxiliary: Auxiliary, days: Double) -> [SceneRow] {
        let byScene = Dictionary(grouping: rows, by: \.scene)
        var scenes = Set(byScene.keys)
        for key in Set(auxiliary.rewrites.keys).union(auxiliary.pauses.keys).union(auxiliary.phrases.keys) where PersonalScene(key: key) != nil {
            scenes.insert(key)
        }
        return scenes.sorted().map { scene in
            let commits = byScene[scene] ?? []
            let normal = commits.filter { normalKinds.contains($0.kind) }
            let closing = normal.filter { $0.surface.last.map { "。！？!?\n".contains($0) } == true }.count
            let pairs = zip(normal, normal.dropFirst()).filter { first, next in
                next.ts > first.ts && next.ts - first.ts < 60 && first.surface.last.map { "。！？!?\n".contains($0) } == true
            }.count
            let perDay = Double(commits.count) / max(1, days)
            var kinds = Dictionary(uniqueKeysWithValues: ["normal", "ai", "idle", "rewrite", "skeleton", "completion", "other"].map { ($0, 0) })
            for row in commits {
                let kind = normalKinds.contains(row.kind) ? "normal" : (kinds[row.kind] == nil ? "other" : row.kind)
                kinds[kind, default: 0] += 1
            }
            var inventory: [String: Inventory] = [:]
            for (name, available, target, basis) in [("closing", closing, 5, "sentence-end-opportunities"),
                                                     ("connective", pairs, 5, "adjacent-sentence-pairs"),
                                                     ("phrases", auxiliary.phrases[scene] ?? 0, 20, "lexicon-count>=3-length4...12"),
                                                     ("rewrite", auxiliary.rewrites[scene] ?? 0, 3, "rewrite-rows")] {
                inventory[name] = Inventory(available: available, target: target,
                                            optimisticDays: perDay > 0 ? Double(max(0, target - available)) / perDay : nil, basis: basis)
            }
            return SceneRow(scene: scene, commits: commits.count, nonDefault: commits.filter { $0.first != nil && $0.first != $0.surface }.count,
                            kinds: kinds, emptyLeft: commits.filter { ($0.left ?? "").isEmpty }.count,
                            rewrites: auxiliary.rewrites[scene] ?? 0, pauses: auxiliary.pauses[scene] ?? 0, commitsPerDay: perDay, inventory: inventory)
        }
    }
}
