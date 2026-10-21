// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

#if os(macOS)
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = ["ZenzaiANE"]
#else
// for testing in Ubuntu environment.
let kanaKanjiConverterTraits: Set<Package.Dependency.Trait> = []
#endif

var products: [Product] = [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
        name: "Core",
        targets: ["Core"]
    )
]

var targets: [Target] = [
    .executableTarget(
        name: "git-info-generator"
    ),
    .plugin(
        name: "GitInfoPlugin",
        capability: .buildTool(),
        dependencies: [.target(name: "git-info-generator")]
    ),
    .target(
        name: "Core",
        dependencies: [
            .product(name: "SwiftUtils", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .target(name: "Gemma4ANE", condition: .when(platforms: [.macOS]))
        ],
        swiftSettings: [.interoperabilityMode(.Cxx)],
        plugins: [
            .plugin(name: "GitInfoPlugin")
        ]
    ),
    // llm-ime: Apple Neural Engine 上の Gemma 4 による続き予測
    .target(
        name: "Gemma4ANE"
    ),
    .testTarget(
        name: "CoreTests",
        dependencies: ["Core", "Gemma4ANE"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    )
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "gemma4bench",
        dependencies: ["Gemma4ANE"]
    )
)
targets.append(.executableTarget(name: "windowcontextbench", dependencies: ["Core", "Gemma4ANE"], swiftSettings: [.interoperabilityMode(.Cxx)]))
// llm-ime: ローカル LLM。入力サーバーと解析・学習のヘルパーが、モデルを同時に持たないように使う
targets.append(
    .target(
        name: "LocalLLM",
        dependencies: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            // Gemma 4 以外のモデルの tokenizer.json とチャットテンプレート（変換エンジンと同じパッケージ）
            .product(name: "Transformers", package: "swift-tokenizers"),
            "Gemma4ANE"
        ]
    )
)
// llm-ime: 場面学習の評価（確定の記録を再生して、個人化あり／なしを比べる）
targets.append(
    .executableTarget(
        name: "personaleval",
        dependencies: ["Core", "Gemma4ANE", "LocalLLM"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    )
)
targets.append(
    .executableTarget(
        name: "localllmbench",
        dependencies: ["Core", "LocalLLM"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    )
)
// llm-ime: 解析と学習（ConverterServer が必要なときだけ起動する。記録の写しを読み、結果は置き場所に書く）
products.append(
    .executable(
        name: "ShizukuLab",
        targets: ["ShizukuLab"]
    )
)
// サンドボックスで動くので、バイナリに Info.plist（CFBundleIdentifier）を埋め込む
let shizukuLabInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/ShizukuLab/Info.plist").path
targets.append(
    .executableTarget(
        name: "ShizukuLab",
        dependencies: ["Core", "LocalLLM", "Gemma4ANE"],
        exclude: ["Info.plist"],
        swiftSettings: [.interoperabilityMode(.Cxx)],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", shizukuLabInfoPlist])]
    )
)
products.append(
    .executable(
        name: "ConverterServer",
        targets: ["ConverterServer"]
    )
)
// Give the background helper the product name in macOS privacy indicators.
let converterServerInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/ConverterServer/Info.plist").path
targets.append(
    .executableTarget(
        name: "ConverterServer",
        dependencies: ["Core", "LocalLLM", "Gemma4ANE"],
        exclude: ["Info.plist"],
        swiftSettings: [.interoperabilityMode(.Cxx)],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", converterServerInfoPlist])]
    )
)
#endif

let package = Package(
    name: "Core",
    // llm-ime: MLX（macOS 14 以上）と Gemma 4 の ANE 実行（MLState、macOS 15 以上）のため 15 に上げる
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: [
        // llm-ime: Core ML / Apple Neural Engine で zenz を動かすフォーク（ad714fe + ZenzaiANE trait）
        .package(path: "../../AzooKeyKanaKanjiConverter", traits: kanaKanjiConverterTraits),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        // llm-ime: ローカル LLM（実行時は通信しない。重みはローカルのディレクトリから読む）
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        // llm-ime: 変換エンジン（AzooKeyKanaKanjiConverter）が使うものと同じ。ローカル LLM の汎用トークナイザに使う
        .package(url: "https://github.com/ensan-hcl/swift-tokenizers", from: "0.0.1")
    ],
    targets: targets
)
