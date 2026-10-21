import Crypto
import Foundation

/// モデルの設定と重み・字句分割器のファイル情報。別のモデルにアダプタを当てないために使う。
public struct LabModelStamp: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var bytes: Int64
        public var modified: Double
    }
    public var name: String
    public var configHash: String
    public var files: [File]

    public static func read(directory: URL) throws -> Self {
        let config = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard config.count <= 1_048_576 else { throw LabError.invalidResult("モデルの設定が大きすぎる") }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasSuffix(".safetensors") || ["tokenizer.bin", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"].contains($0)
        }.sorted()
        let files = try names.map { name -> File in
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else {
                throw LabError.invalidResult("モデルのファイルを確認できない")
            }
            return File(name: name, bytes: bytes.int64Value, modified: date.timeIntervalSince1970)
        }
        guard !files.isEmpty, files.count <= 128, files.contains(where: { $0.name.hasSuffix(".safetensors") }) else {
            throw LabError.invalidResult("モデルの重みがない")
        }
        return Self(name: directory.lastPathComponent, configHash: LabArtifact.hash(config), files: files)
    }

    public func matches(directory: URL) -> Bool { (try? Self.read(directory: directory)) == self }
}

/// 版に含める文章由来の成果物。名前とハッシュをサーバーが確認してからコピーする。
public struct LabArtifact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case knowledge, adapter, report }
    public var kind: Kind
    public var name: String
    public var digest: String
    public var bytes: Int64
    public var dataFrom: Double
    public var dataTo: Double

    public static let maximumBytes: Int64 = 64 * 1024 * 1024
    public static let names: [Kind: String] = [.knowledge: "knowledge.json", .adapter: "adapter", .report: "report.json"]
    public static let adapterFiles: Set<String> = ["adapter_config.json", "adapters.safetensors", "training.json"]

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func validDigest(_ value: String?) -> Bool {
        value == nil || (value!.utf8.count == 64 && value!.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    }

    public static func measure(kind: Kind, root: URL, dataFrom: Double, dataTo: Double) throws -> Self {
        let name = Self.names[kind]!
        let url = root.appendingPathComponent(name)
        let fm = FileManager.default
        let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        let files: [String]
        if kind == .adapter {
            guard type == .typeDirectory else { throw LabError.invalidResult("アダプタの場所が不正") }
            files = try fm.contentsOfDirectory(atPath: url.path).sorted()
            guard Set(files) == Self.adapterFiles else { throw LabError.invalidResult("アダプタに許されないファイルがある") }
        } else {
            guard type == .typeRegular else { throw LabError.invalidResult("成果物が通常のファイルではない") }
            files = [name]
        }
        var sha = SHA256()
        var total: Int64 = 0
        for file in files {
            let path = kind == .adapter ? url.appendingPathComponent(file) : url
            let attrs = try fm.attributesOfItem(atPath: path.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? NSNumber else {
                throw LabError.invalidResult("成果物にリンクまたは通常でないファイルがある")
            }
            total += size.int64Value
            guard total > 0, total <= Self.maximumBytes else { throw LabError.invalidResult("成果物の大きさが範囲外") }
            if kind == .adapter { sha.update(data: Data((file + "\u{0}").utf8)) }
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { sha.update(data: data) }
        }
        return Self(kind: kind, name: name, digest: sha.finalize().map { String(format: "%02x", $0) }.joined(),
                    bytes: total, dataFrom: dataFrom, dataTo: dataTo)
    }

    public func verified(root: URL, split: Double) -> Bool {
        guard self.name == Self.names[self.kind], Self.validDigest(self.digest), self.bytes > 0, self.bytes <= Self.maximumBytes,
              self.dataFrom.isFinite, self.dataTo.isFinite, self.dataFrom <= self.dataTo, self.dataTo < split else { return false }
        return (try? Self.measure(kind: self.kind, root: root, dataFrom: self.dataFrom, dataTo: self.dataTo)) == self
    }
}

/// LoRA の学習条件と対応モデル。数値はモデルの提案で変更せず、決まった小さい範囲だけを使う。
public struct LabAdapterMetadata: Codable, Equatable, Sendable {
    public var model: LabModelStamp
    public var rank: Int
    public var layers: Int
    public var iterations: Int
    public var sequenceLength: Int
    public var learningRate: Double
    public var seed: UInt64
    public var samples: Int
    public var finalLoss: Double

    public init(model: LabModelStamp, rank: Int, layers: Int, iterations: Int, sequenceLength: Int, learningRate: Double,
                seed: UInt64, samples: Int, finalLoss: Double) {
        self.model = model; self.rank = rank; self.layers = layers; self.iterations = iterations
        self.sequenceLength = sequenceLength; self.learningRate = learningRate; self.seed = seed
        self.samples = samples; self.finalLoss = finalLoss
    }

    public var isWithinBounds: Bool {
        (2...16).contains(self.rank) && (1...8).contains(self.layers) && (1...96).contains(self.iterations)
            && (32...256).contains(self.sequenceLength) && (0.000001...0.0001).contains(self.learningRate)
            && self.samples > 0 && self.finalLoss.isFinite && self.finalLoss >= 0
    }
    public static func read(at directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("training.json")), data.count <= 65536 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func validConfiguration(at directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("adapter_config.json")), data.count <= 16384,
              let c = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              c["num_layers"] as? Int == self.layers, c["fine_tune_type"] as? String == "lora",
              let p = c["lora_parameters"] as? [String: Any], p["rank"] as? Int == self.rank,
              p["scale"] as? Double == 10, p["dropout"] as? Double == 0,
              let keys = p["keys"] as? [String], (1...16).contains(keys.count),
              keys.allSatisfy({ $0.hasSuffix("q_proj") || $0.hasSuffix("v_proj") }) else { return false }
        return self.isWithinBounds
    }
}
