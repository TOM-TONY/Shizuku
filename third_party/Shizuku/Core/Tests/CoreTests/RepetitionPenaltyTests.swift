import Gemma4ANE
import Testing

@Test func repetitionPenaltyAllowsShortRepeats() {
    let penalty = Gemma4Completer.RepetitionPenalty()
    // 文脈: 1 2 3 4 5 … 9 1 → 次に 2 を置くと「1 2」をなぞる（なぞる長さ 1）ので下げない
    #expect(penalty.penalty(tokens: [1, 2, 3, 4, 5, 9, 1], candidate: 2) == 0)
    // 文脈にない候補は下げない
    #expect(penalty.penalty(tokens: [1, 2, 3, 4, 5, 9, 1, 2, 3], candidate: 7) == 0)
}

@Test func repetitionPenaltyGrowsWithLength() {
    let penalty = Gemma4Completer.RepetitionPenalty()
    // 「1 2 3」の後に 4 を置くと長さ 3 の並びをなぞる
    let three = penalty.penalty(tokens: [1, 2, 3, 4, 5, 9, 1, 2, 3], candidate: 4)
    let four = penalty.penalty(tokens: [1, 2, 3, 4, 5, 9, 1, 2, 3, 4], candidate: 5)
    #expect(three > 0)
    #expect(four > three)
}
