import ArgumentParser
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils

extension Subcommands {
    /// llm-ime: 打鍵ミス訂正（experimentalRequestTypoCorrection）を一括評価する。
    ///
    /// 入力 JSON の各項目はローマ字打鍵列 `typed`（誤りを含みうる）と、誤りのない `clean`、
    /// 意図した読み `intended_reading` を持つ。IME と同じ `.mapped(id: .defaultRomanToKana)` で
    /// 読みに変換し、訂正候補を出力する。集計は eval/typo_metrics.py で行う。
    struct TypoEvaluate: AsyncParsableCommand {
        @Argument(help: "typed, clean, intended_reading, left_context を持つ JSON ファイル")
        var inputFile: String
        @Option(name: [.customLong("output")], help: "結果 JSON の出力先")
        var outputFilePath: String
        @OptionGroup
        var options: SharedConversionOptions
        @Option(name: [.customLong("typo_lm")], help: "zenz または ngram:<prefix>")
        var typoLM: String = "zenz"
        @Option(name: [.customLong("typo_beam")]) var beamSize: Int = 32
        @Option(name: [.customLong("typo_topk")]) var topK: Int = 64
        @Option(name: [.customLong("typo_nbest")]) var nBest: Int = 5
        @Option(name: [.customLong("typo_alpha")], help: "置換のチャネルコスト") var alpha: Float = 2.0
        @Option(name: [.customLong("typo_beta")], help: "余計な 1 打のチャネルコスト") var beta: Float = 3.0
        @Option(name: [.customLong("typo_gamma")], help: "入れ替えのチャネルコスト") var gamma: Float = 2.0
        @Option(name: [.customLong("typo_delta")], help: "打ち漏れのチャネルコスト") var delta: Float = 3.0
        @Option(name: [.customLong("typo_double")], help: "二度押しのチャネルコスト") var doublePress: Float = 2.0
        @Option(name: [.customLong("limit")], help: "先頭から評価する件数") var limit: Int = .max
        @Flag(name: [.customLong("incremental")], help: "1 キーずつ打つ状況を再現し、キーごとの時間を記録する")
        var incremental = false
        @Flag(name: [.customLong("verify")], help: "最良の別候補を zenz で検証し、対数確率の差を記録する")
        var verify = false

        static let configuration = CommandConfiguration(
            commandName: "typo_evaluate",
            abstract: "Evaluate experimental typo correction on romaji keystroke inputs."
        )

        struct Item: Codable {
            var typed: String
            var clean: String
            var intended_reading: String
            var left_context: String?
            var error: String?
            var source: String?
        }

        struct Candidate: Codable {
            var corrected_input: String
            var converted_text: String
            var score: Float
            var lm_score: Float
            var channel_cost: Float
            var prominence: Float
        }

        struct Output: Codable {
            var typed: String
            var typed_reading: String
            var clean_reading: String
            var intended_reading: String
            var error: String?
            var source: String?
            var elapsed_ms: Double
            var per_key_ms: [Double]?
            var verify_margin: Float?
            var verify_ms: Double?
            var candidates: [Candidate]
        }

        mutating func run() async throws {
            let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: self.inputFile)))
            let converter = KanaKanjiConverter.withDefaultDictionary()
            let inputStyle: InputStyle = .mapped(id: .defaultRomanToKana)
            let languageModel: ExperimentalTypoCorrectionConfig.LanguageModel
            if self.typoLM.hasPrefix("ngram:") {
                languageModel = .ngram(.init(prefix: String(self.typoLM.dropFirst("ngram:".count)), n: 5, d: 0.75))
            } else {
                languageModel = .zenz
            }
            let config = ExperimentalTypoCorrectionConfig(
                languageModel: languageModel,
                beamSize: self.beamSize,
                topK: self.topK,
                nBest: self.nBest,
                alpha: self.alpha,
                beta: self.beta,
                gamma: self.gamma,
                delta: self.delta,
                doublePress: self.doublePress
            )
            var outputs: [Output] = []
            for item in items.prefix(self.limit) {
                var typed = ComposingText()
                typed.insertAtCursorPosition(item.typed, inputStyle: inputStyle)
                var clean = ComposingText()
                clean.insertAtCursorPosition(item.clean, inputStyle: inputStyle)
                let leftSideContext = item.left_context ?? ""
                let options = try self.options.makeEvaluateRequestOptions(
                    leftSideContext: leftSideContext,
                    rightSideContext: nil,
                    ignoreLeftContext: false,
                    ignoreRightContext: true
                )
                var perKey: [Double]? = nil
                if self.incremental {
                    // 1 キーずつ伸ばしながら呼び、IME で打鍵するたびに発生する処理時間を測る
                    var times: [Double] = []
                    var prefix = ComposingText()
                    for ch in item.typed.dropLast() {
                        prefix.insertAtCursorPosition(String(ch), inputStyle: inputStyle)
                        let t0 = Date()
                        _ = converter.experimentalRequestTypoCorrection(
                            leftSideContext: leftSideContext,
                            composingText: prefix,
                            options: options,
                            inputStyle: inputStyle,
                            config: config
                        )
                        times.append(Date().timeIntervalSince(t0) * 1000)
                    }
                    perKey = times
                }
                let start = Date()
                let candidates = converter.experimentalRequestTypoCorrection(
                    leftSideContext: leftSideContext,
                    composingText: typed,
                    options: options,
                    inputStyle: inputStyle,
                    config: config
                )
                let elapsed = Date().timeIntervalSince(start) * 1000
                perKey?.append(elapsed)
                var verifyMargin: Float? = nil
                var verifyMs: Double? = nil
                let identity = candidates.first(where: { $0.convertedText.toKatakana() == typed.convertTarget.toKatakana() })
                if self.verify,
                   let alternative = candidates.first(where: { $0.convertedText.toKatakana() != typed.convertTarget.toKatakana() }),
                   alternative.score - (identity?.score ?? -.infinity) > 1.0 {
                    let t0 = Date()
                    if let alt = converter.experimentalReadingLogProbability(reading: alternative.convertedText, leftSideContext: leftSideContext, options: options),
                       let orig = converter.experimentalReadingLogProbability(reading: typed.convertTarget, leftSideContext: leftSideContext, options: options) {
                        verifyMargin = alt - orig
                    }
                    verifyMs = Date().timeIntervalSince(t0) * 1000
                }
                outputs.append(Output(
                    typed: item.typed,
                    typed_reading: typed.convertTarget,
                    clean_reading: clean.convertTarget,
                    intended_reading: item.intended_reading,
                    error: item.error,
                    source: item.source,
                    elapsed_ms: elapsed,
                    per_key_ms: perKey,
                    verify_margin: verifyMargin,
                    verify_ms: verifyMs,
                    candidates: candidates.map {
                        Candidate(
                            corrected_input: $0.correctedInput,
                            converted_text: $0.convertedText,
                            score: $0.score,
                            lm_score: $0.lmScore,
                            channel_cost: $0.channelCost,
                            prominence: $0.prominence
                        )
                    }
                ))
                converter.stopComposition()
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(outputs).write(to: URL(fileURLWithPath: self.outputFilePath))
        }
    }
}
