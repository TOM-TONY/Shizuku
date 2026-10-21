# 第三者ライセンス

このリポジトリのMIT Licenseは、第三者のコード・辞書・モデルのライセンスを置き換えません。

| 構成要素 | 出典・ライセンス |
| --- | --- |
| 入力メソッドの基礎 | [azooKey-Desktop](https://github.com/azooKey/azooKey-Desktop)、MIT。`third_party/Shizuku/LICENSE`を参照 |
| かな漢字変換エンジン | [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)、MIT。同ディレクトリの`LICENSE`を参照 |
| 基本辞書 | [azooKey_dictionary_storage](https://github.com/ensan-hcl/azooKey_dictionary_storage)、Apache License 2.0。固定コミットを参照 |
| 絵文字辞書 | [azooKey_emoji_dictionary_storage](https://github.com/ensan-hcl/azooKey_emoji_dictionary_storage)。上流の固定コミット・元データの表示を参照 |
| ローカルLLM | [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)とその依存ライブラリ。Swift Package Managerで取得 |
| 埋め込みモデル | [ruri-v3-30m](https://huggingface.co/cl-nagoya/ruri-v3-30m)。`tools/dist/ruri-v3-LICENSE.txt`を参照 |

その他のSwiftパッケージの出典と固定バージョンは`Package.swift`と`Package.resolved`に記録しています。モデルの重みは同梱していません。モデルを入手・変換・配布する際は、各提供元の利用条件と`tools/dist/MODELS_NOTICE.txt`を確認してください。
