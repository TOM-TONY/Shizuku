# モデルの準備

重みや変換済みモデルはGitリポジトリへ含めません。提供元の利用条件を確認し、自分で取得したローカルのファイルから変換してください。変換には時間・メモリ・ディスク容量が必要です。

## かな漢字変換

[zenz-v2.5-medium](https://huggingface.co/Miwa-Keita/zenz-v2.5-medium)をCore MLへ変換し、次へ配置します。

```text
third_party/Shizuku/Shizuku/Resources/zenz-ane/zenz-v2.5-medium-ane.mlmodelc/
```

変換コードは`zenz/ane_gpt2.py`、元モデルの実装と比較するコードは`zenz/reference.py`と`zenz/verify.py`です。各ツールのヘルプで系列長・数値精度の設定を確認してください。`.mlpackage`は`xcrun coremlcompiler compile`で`.mlmodelc`へコンパイルします。変換時には複数の系列長と元モデルとの出力比較を確認してください。

補助のn-gramモデルは上流の[base_n5_lm](https://huggingface.co/Miwa-Keita/base_n5_lm)、GGUFは[zenz-v3.2-small-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf)を参照してください。配置先はそれぞれ`Resources/base_n5_lm/`と`Resources/gguf/`です。

打ち間違い訂正には[input_n5_lm_v1](https://huggingface.co/Miwa-Keita/input_n5_lm_v1)のZIPを展開し、`Resources/typo-lm/input_n5_lm_v1/`へ配置します。`lm_c_abc.marisa`、`lm_c_bc.marisa`、`lm_r_xbx.marisa`、`lm_u_abx.marisa`、`lm_u_xbc.marisa`の5ファイルが必要です。

## 続き予測・書き直し

Neural Engine向けのGemma 4 E2B/E4B変換コードは`gemma4/convert_gemma4.py`にあります。元のHugging Face形式の重みをローカルの入力ディレクトリとして指定します。

変換後のディレクトリには`meta.json`とCore MLチャンクが必要です。`gemma4-e2b-ane`または`gemma4-e4b-ane`として、`~/Library/Application Support/llm-ime/models/`に配置します。書き直し・解析用には、設定で選択可能なMLX形式のローカルモデルを同じモデル保存先へ置きます。

## 文の埋め込み

[ruri-v3-30m](https://huggingface.co/cl-nagoya/ruri-v3-30m)の固定版を使います。変換・パッケージ化のツールは`tools/embedding/`にあり、必要なPythonパッケージは同ディレクトリの`requirements.txt`に記載しています。

`convert_embeddinggemma2_coreml.py`と`package_embeddinggemma2.sh`は、EmbeddingGemma 2のテキスト部分を同じ形式へ変換する追加のツールです。`jsts_retrieval.py`は、公開データJGLUEのJSTSで文の埋め込みのモデルを比べます。

パッケージ名は`ruri-v3-30m-coreml`です。`embedding.json`、`tokenizer.json`、`embedder.mlmodelc/`、ライセンスを揃えてモデル保存先へ配置します。埋め込みモデルを含む配布物を作る場合は、`tools/dist/dmg_models.py`の検証を通してください。

モデル変換用のPythonパッケージは仮想環境へインストールしてください。グローバル環境やモデル提供元のソースを変更する必要はありません。
