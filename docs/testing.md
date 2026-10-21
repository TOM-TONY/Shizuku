# テスト

通常の単体テストは次で実行します。

```sh
swift test --package-path third_party/Shizuku/Core
python3 tools/dist/test_dmg_models.py
```

Coreのテストは合成した入力・試験用ディレクトリを使います。普段使いの個人化データをテストの材料へ渡さないでください。

## 入力クライアントと再接続

Releaseビルド後、同じDerivedDataを指定します。これらの既定モードは試験用の通信境界を使い、IMEの登録・起動、LaunchAgentへの接続、本人の設定の変更を行いません。

```sh
python3 third_party/Shizuku/Tools/test_client_initialization.py \
  --derived-data build/DerivedData --out build/client-tests
python3 third_party/Shizuku/Tools/test_converter_settings_reconnect.py \
  --derived-data build/DerivedData --out build/reconnect-tests
```

`--test-server-shutdown`は実際の試験サーバーを操作する追加モードです。独立した試験環境と復元手順を用意した場合だけ使用してください。

## 準備完了の通知

匿名XPCリスナーを使う検査です。実際の変換サービスや個人用記録を使いません。

```sh
mkdir -p build/readiness-tests
swiftc -swift-version 5 -parse-as-library \
  third_party/Shizuku/Core/Sources/ConverterServer/ConverterServerReadiness.swift \
  third_party/Shizuku/Tools/ConverterReadinessTests.swift \
  -o build/readiness-tests/run
build/readiness-tests/run
```

## ウィンドウの参照

この検査は、検査プロセスが作る合成ウィンドウだけを読み取ります。保存先は検査用に隔離した一時ディレクトリで、入力メソッドの登録やインストール済みのサービスへの接続は行いません。OSの権限も要求しません。ConverterServerをビルドし、その実行ファイルにアクセシビリティと画面収録の権限が与えられている環境で実行します。かな漢字変換と続き予測には、配置済みのローカルモデルを指定します。

```sh
swift build --package-path third_party/Shizuku/Core -c release --product ConverterServer
python3 third_party/Shizuku/Tools/test_window_context_e2e.py \
  --server third_party/Shizuku/Core/.build/release/ConverterServer \
  --out build/window-context-tests \
  --resources third_party/Shizuku/Shizuku/Resources \
  --completion-model "$HOME/Library/Application Support/llm-ime/models/gemma4-e4b-ane"
```

終了後に、参照した文章・画像・ベクトルが保存先に残っていないことを検査します。合成の文章で検索と候補の並べ替えの時間を測る場合は、`swift run --package-path third_party/Shizuku/Core -c release windowcontextbench`を使います。

実機入力の確認は日常の文書と分けた試験用アプリ・記録先で行い、本文を不具合報告へ載せないでください。
