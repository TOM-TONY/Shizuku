/// 完了処理の分岐。測定は採否・版の処理を呼べないよう、呼出し側でもこの入口を共有する。
public enum LabJobKind: Sendable {
    case analysis
    case upperBound

    public func finish(upperBound: () -> Void, analysis: () -> Void) {
        switch self {
        case .upperBound: upperBound()
        case .analysis: analysis()
        }
    }
}
