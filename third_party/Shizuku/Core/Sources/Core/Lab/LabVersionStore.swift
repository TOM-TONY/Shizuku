import Foundation

// MARK: - 解析と学習の版（llm-ime、解析と学習 段階 A）
//
// 採用した変更を版として残す（personal/lab/versions/<n>/manifest.json）。今の版は current（版の番号。0 なら既定＝解析を入れる前）。
// 「元に戻す」は今の版の親に戻す。記録をアプリごと・全部消したら、文章から作ったもの（索引・文体の説明・アダプタ）を消し、
// それを持つ版は使えないことにして、今の版を、使える最も新しい祖先（なければ既定）に戻す。値（LabParameters）には文章は入らない。

public final class LabVersionStore: @unchecked Sendable {
    public struct Manifest: Codable, Equatable, Sendable {
        public var version: Int
        public var parent: Int
        public var createdAt: Double
        public var runID: String
        public var split: Double?
        public var dataFrom: Double?
        public var dataTo: Double?
        public var parameters: LabParameters
        /// 採否の判定（案 − その時の版）
        public var decision: LabGate.Decision?
        /// 文章から作ったもの（版のフォルダの中の名前。段階 B〜D）。gated は取り置きを除いて作り答え合わせに通したもの、refit は全部で作り直したもの
        public var artifacts: [String: String]
        public var gatedArtifacts: [String: String]
        /// 記録が消されて、文章から作ったものを消した（この版は使わない）
        public var invalid: Bool
        public var note: String
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var versionsURL: URL {
        self.directory.appendingPathComponent("versions", isDirectory: true)
    }

    private var currentURL: URL {
        self.directory.appendingPathComponent("current")
    }

    public func folder(of version: Int) -> URL {
        self.versionsURL.appendingPathComponent(String(version), isDirectory: true)
    }

    public func manifest(_ version: Int) -> Manifest? {
        guard version > 0, let data = try? Data(contentsOf: self.folder(of: version).appendingPathComponent("manifest.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    public func allVersions() -> [Manifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.versionsURL.path)) ?? []
        return names.compactMap(Int.init).sorted().compactMap(self.manifest)
    }

    /// 今の版の番号（0 なら既定）
    public var currentVersion: Int {
        guard let text = try? String(contentsOf: self.currentURL, encoding: .utf8), let version = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return version
    }

    public func current() -> Manifest? {
        self.manifest(self.currentVersion)
    }

    /// 今使う値（版がなければ既定）
    public var appliedParameters: LabParameters {
        guard let current = self.current(), !current.invalid else { return .defaults }
        return current.parameters
    }

    public func currentAsset(_ kind: LabArtifact.Kind) -> URL? {
        guard let current = self.current(), !current.invalid,
              current.gatedArtifacts[kind.rawValue] == LabArtifact.names[kind] else { return nil }
        let root = self.folder(of: current.version)
        let id = kind == .knowledge ? current.parameters.knowledgeID : kind == .adapter ? current.parameters.adapterID : nil
        guard let measured = try? LabArtifact.measure(kind: kind, root: root, dataFrom: 0, dataTo: 0),
              kind == .report || measured.digest == id else { return nil }
        return root.appendingPathComponent(measured.name)
    }

    /// 確かめた成果物を先にコピーし、すべてそろってから今の版を切り替える。再学習はせず、評価した重みを保存する。
    @discardableResult
    public func adopt(result: LabRunResult, candidate: LabParameters, decision: LabGate.Decision, staging: URL, note: String) throws -> Manifest {
        guard result.artifacts.count <= 3, Set(result.artifacts.map(\.kind)).count == result.artifacts.count,
              result.artifacts.allSatisfy({ $0.verified(root: staging, split: result.split) }) else {
            throw LabError.invalidResult("成果物の名前・ハッシュ・学習期間が合わない")
        }
        let version = (self.allVersions().map(\.version).max() ?? 0) + 1
        let folder = self.folder(of: version)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var artifacts: [String: String] = [:]
        do {
            for kind in [LabArtifact.Kind.knowledge, .adapter, .report] {
                let id = kind == .knowledge ? candidate.knowledgeID : kind == .adapter ? candidate.adapterID : nil
                let supplied = result.artifacts.first { $0.kind == kind }
                let source: URL?
                if let supplied, kind == .report || supplied.digest == id {
                    source = staging.appendingPathComponent(supplied.name)
                } else {
                    let oldID = kind == .knowledge ? self.appliedParameters.knowledgeID : self.appliedParameters.adapterID
                    source = kind != .report && id != nil && id == oldID ? self.currentAsset(kind) : nil
                }
                guard let source else {
                    if id != nil { throw LabError.invalidResult("評価した成果物がない") }
                    continue
                }
                let name = LabArtifact.names[kind]!
                try fm.copyItem(at: source, to: folder.appendingPathComponent(name))
                artifacts[kind.rawValue] = name
            }
            return try self.adopt(parameters: candidate, decision: decision, runID: result.runID, split: result.split,
                                  dataFrom: result.dataFrom, dataTo: result.dataTo, gatedArtifacts: artifacts, note: note)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    public func export(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: self.versionsURL.path) {
            try FileManager.default.copyItem(at: self.versionsURL, to: directory.appendingPathComponent("versions"))
        }
        try String(self.currentVersion).write(to: directory.appendingPathComponent("current"), atomically: true, encoding: .utf8)
        let report = self.directory.appendingPathComponent("last-report.json")
        if FileManager.default.fileExists(atPath: report.path) { try FileManager.default.copyItem(at: report, to: directory.appendingPathComponent("last-report.json")) }
    }

    private func write(_ manifest: Manifest) throws {
        let folder = self.folder(of: manifest.version)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func setCurrent(_ version: Int) throws {
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try String(version).write(to: self.currentURL, atomically: true, encoding: .utf8)
    }

    /// 新しい版として採用する（親は今の版）。範囲外の値は採用しない
    @discardableResult
    public func adopt(
        parameters: LabParameters, decision: LabGate.Decision?, runID: String, split: Double?, dataFrom: Double?, dataTo: Double?,
        artifacts: [String: String] = [:], gatedArtifacts: [String: String] = [:], note: String = "", now: Date = Date()
    ) throws -> Manifest {
        guard parameters.isWithinBounds else {
            throw LabError.outOfBounds
        }
        let version = (self.allVersions().map(\.version).max() ?? 0) + 1
        let manifest = Manifest(
            version: version, parent: self.currentVersion, createdAt: now.timeIntervalSince1970, runID: runID, split: split,
            dataFrom: dataFrom, dataTo: dataTo, parameters: parameters, decision: decision, artifacts: artifacts,
            gatedArtifacts: gatedArtifacts, invalid: false, note: note
        )
        try self.write(manifest)
        try self.setCurrent(version)
        return manifest
    }

    /// 今の版の親（使える最も近い祖先）に戻す。戻った先の版（既定なら nil）
    @discardableResult
    public func undo() throws -> Manifest? {
        guard let current = self.current() else {
            return nil
        }
        let target = self.validAncestor(from: current.parent)
        try self.setCurrent(target?.version ?? 0)
        return target
    }

    private func validAncestor(from version: Int) -> Manifest? {
        var next = version
        while next > 0, let manifest = self.manifest(next) {
            if !manifest.invalid {
                return manifest
            }
            next = manifest.parent
        }
        return nil
    }

    /// 記録が消されたとき: 文章から作ったもの（索引・文体の説明・アダプタ）をすべての版から消し、それを持つ版は使わない。
    /// 今の版が使えなくなったら、使える最も新しい祖先（なければ既定）に戻す
    public func invalidateTextArtifacts() throws {
        for var manifest in self.allVersions() where !manifest.artifacts.isEmpty || !manifest.gatedArtifacts.isEmpty {
            for name in Set(manifest.artifacts.values).union(manifest.gatedArtifacts.values) {
                guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { continue }
                try? FileManager.default.removeItem(at: self.folder(of: manifest.version).appendingPathComponent(name))
            }
            manifest.artifacts = [:]
            manifest.gatedArtifacts = [:]
            manifest.invalid = true
            try self.write(manifest)
        }
        try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("last-report.json"))
        if let current = self.current(), current.invalid {
            try self.setCurrent(self.validAncestor(from: current.parent)?.version ?? 0)
        }
    }

    /// すべての版を消す（全部消すとき）
    public func removeAll() throws {
        try? FileManager.default.removeItem(at: self.versionsURL)
        try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("last-report.json"))
        try self.setCurrent(0)
    }
}

public enum LabError: Error, Equatable {
    case outOfBounds
    case snapshotMismatch
    case invalidResult(String)
    /// 続き予測の再生で、全部の位置の結果がそろわなかった（そろった数、要る数）
    case incompleteReplay(Int, Int)
}
