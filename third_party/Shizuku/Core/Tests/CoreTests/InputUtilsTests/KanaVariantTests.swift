@testable import Core
import Testing

@Test func kanaVariantsReplaceZuAndJiOneByOneAndAll() {
    #expect(SegmentsManager.kanaVariants(of: "つずき") == ["つづき"])
    #expect(SegmentsManager.kanaVariants(of: "ちじむ") == ["ちぢむ"])
    #expect(SegmentsManager.kanaVariants(of: "ずじ") == ["づじ", "ずぢ", "づぢ"])
    #expect(SegmentsManager.kanaVariants(of: "みかん").isEmpty)
    // 該当箇所が多すぎる読みは対象外
    #expect(SegmentsManager.kanaVariants(of: "ずずずず").isEmpty)
}
