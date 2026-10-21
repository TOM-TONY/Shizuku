import Foundation

/// Serverの出口で使う固定順。同じ段の比較は従来の順のまま。
public enum OfferKind: String, CaseIterable, Sendable {
    case typo, rewrite, skeleton, quote, completion, idle, prediction, cleanup
    public var tier: Int {
        switch self {
        case .typo, .rewrite, .cleanup: 3
        case .skeleton, .quote: 2
        case .completion, .idle: 1
        case .prediction: 0
        }
    }
}

public struct Offer: Sendable, Equatable {
    public var kind: OfferKind
    public var text: String
    public var predictions: [ConverterPredictionCandidate]
    public init(_ kind: OfferKind, text: String, predictions: [ConverterPredictionCandidate] = []) {
        self.kind = kind; self.text = text; self.predictions = predictions
    }
}

public struct OfferArbiter: Sendable {
    public static let replacementWindow: UInt64 = 150_000_000
    public private(set) var current: Offer?
    private var firstPresented: UInt64?
    private var recorded: Offer?
    public init() {}
    public mutating func reset() { current = nil; firstPresented = nil; recorded = nil }
    public mutating func invalidateGeneration() {
        if let kind = current?.kind, [.completion, .idle, .skeleton].contains(kind) { reset() }
    }
    public func mayPrepare(_ kind: OfferKind) -> Bool { (current?.kind.tier ?? 0) <= kind.tier }
    public mutating func chooseEmpty(_ proposed: Offer, skeleton: Offer?, now: UInt64, temporal: Bool) -> Offer? {
        var available = skeleton.map { [$0] } ?? []
        if let current, current.kind == .idle, proposed.kind != .idle { available.append(current) }
        available.append(proposed)
        return choose(available, now: now, temporal: temporal)
    }
    /// nowは最初に応答へ載せた瞬間からの単調時計。辞書の予測は150msの起点にしない。
    public mutating func choose(_ offers: [Offer], now: UInt64, temporal: Bool) -> Offer? {
        guard let best = offers.enumerated().max(by: {
            ($0.element.kind.tier, -$0.offset) < ($1.element.kind.tier, -$1.offset)
        })?.element else { current = nil; return nil }
        var chosen = best
        if temporal, let previous = current, previous.kind.tier > 0,
           best.kind.tier > previous.kind.tier, let firstPresented,
           now > firstPresented, now - firstPresented > Self.replacementWindow,
           let retained = offers.first(where: { $0.kind == previous.kind }) {
            chosen = retained
        }
        if current == nil || current?.kind.tier == 0 {
            firstPresented = chosen.kind.tier > 0 ? now : nil
        }
        current = chosen
        return chosen
    }
    public mutating func newlyPresented() -> Offer? {
        guard let current, current.kind != .prediction, current != recorded else { return nil }
        recorded = current
        return current
    }
}
