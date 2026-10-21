import Foundation

/// Core MLの同期呼び出し自体は止めず、各チャンクの前後だけで中断する。
public enum Gemma4ChunkExecution {
    public static func run<S: Sequence>(_ chunks: S, isCancelled: () -> Bool, body: (S.Element) throws -> Void) throws {
        for chunk in chunks {
            if isCancelled() { throw CancellationError() }
            try body(chunk)
        }
        if isCancelled() { throw CancellationError() }
    }
}
