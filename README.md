# Shizuku（しずく）

AppleシリコンのMacで動く日本語入力システムです。かな漢字変換、文章の続きの予測、添削・書き直しをローカルのモデルで行います。

## 主な機能

- zenzをApple Neural Engineで動かすかな漢字変換
- 入力中や手を止めたときの続き予測と、Tabによる取り込み
- 選択した文章の添削、文体の変更、書き直し
- ライブ変換、ユーザ辞書、ローマ字テーブルの編集
- このMacに保存した入力履歴に基づく個人化と、ローカルモデルによる解析・学習
- 直前に書いた1文の清書（Ctrl+Tabの三択から呼び出し。文末で手を止めたときの自動表示は設定でオン）
- 同じ入力欄のカーソルより前に書いた語を変換候補に使う機能（辞書にない読みも、1字ずつの読みを辞書で確かめて候補にします）
- 入力先ウィンドウに表示された会話・資料の文字を、変換・続き予測・書き直しの参考にする「ウィンドウの参照」（初期値はオフ）
- AIとの会話で、最後の返答から次に送りそうな依頼をローカルLLMで先に作り、空の欄で手を止めたときに表示する機能（「ウィンドウの参照」と手を止めたときの本文生成がオンのとき）

入力処理はローカルで行います。外部APIへの送信はコード内のネットワークポリシーで無効化しています。管理アプリのアップデート確認は別の処理です。

## 動作環境

- AppleシリコンのMac、macOS 15以降
- Xcode 27、Swift 6.2以降（Swiftパッケージの宣言は6.1）
- Python 3.12：モデル変換・補助ツールを使う場合
- モデルを保存するディスク容量と、利用するモデルに応じたメモリ

このリポジトリではソースコードを公開しています。モデルの重み、署名済みアプリ、インストーラーは含みません。

## ソースの取得

```sh
git clone --recurse-submodules https://github.com/TOM-TONY/Shizuku.git
cd Shizuku
python3 tools/setup_local_excludes.py
```

辞書は上流の固定コミットをサブモジュールで参照します。Swiftの依存ライブラリはSwift Package Managerが取得します。

## 署名設定

アプリ、変換サーバー、学習ヘルパーは同じApple DeveloperチームのApp Groupを使います。署名する前に、自分のチームIDでこのチェックアウトを設定してください。

```sh
python3 tools/configure_signing.py YOUR_ACTUAL_TEAM_ID
```

引数はApple Developerの10文字のチームIDです。ソース内の`YOURTEAMID`を置き換えます。アプリIDと設定キーの`dev.tomonari.*`は製品の識別子として維持しています。既存のアプリと同じ識別子を使用するため、普段使いの環境へ配置する際は設定・データの引き継ぎに注意してください。

## モデルの準備

必要なファイルと配置先は[モデルの準備](docs/models.md)を参照してください。モデルは各提供元のライセンスに従って別途用意します。リポジトリの取得やテストによってモデルの重みを自動取得することはありません。

## ビルド

モデルを配置してから実行します。`YOUR_ACTUAL_TEAM_ID`は署名設定に使ったチームIDへ置き換えてください。

```sh
xcodebuild -project third_party/Shizuku/Shizuku.xcodeproj \
  -scheme Shizuku -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'generic/platform=macOS' \
  ARCHS=arm64 \
  DEVELOPMENT_TEAM=YOUR_ACTUAL_TEAM_ID build
```

生成先は`build/DerivedData/Build/Products/Release/Shizuku.app`です。コンパイルだけを確認する場合は、署名設定を行わず、上記の`DEVELOPMENT_TEAM`の代わりに`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`を指定できます。この署名なしのアプリは日常利用や配布用ではありません。

配布用管理アプリとDMGを作るツールは`tools/dist/`にあります。利用時には`SHIZUKU_TEAM_ID`、自分の署名証明書、公証設定、配布対象モデルが必要です。更新署名の秘密鍵はリポジトリへ保存しないでください。

## インストールと使い方

署名済みのアプリを`~/Library/Input Methods/Shizuku.app`へ配置し、`third_party/Shizuku/Tools/install_converter_server_launch_agent.sh`にそのアプリのパスを渡して変換サーバーを登録します。インストール処理は自動では実行されません。

システム設定の「キーボード」→「入力ソース」で「Shizuku (日本語)」を追加します。アプリを更新した場合は、入力ソースを切り替えるか、必要に応じてログインし直してください。

- 続き予測は候補の窓に表示され、Tabで取り込めます（設定で入力中の文字の後ろに灰色で重ねる表示にもできます）。Shift+Tabは全体の取り込み、Escは取消です。
- 手を止めたときの本文生成には「放置で続きを自動生成」に加え、「助けの設定」→「何を言ってよいか」で「本文の生成まで」が必要です。
- 選択した文章への操作や設定は、入力メニューから呼び出せます。
- 「ウィンドウの参照」を使うには、設定の「ウィンドウの参照」で有効にし、変換サーバーにアクセシビリティを許可します。画像の中の文字も読む場合は画面収録も許可します。読み取らないアプリを設定で指定でき、入力メニューから今のアプリを除外することもできます。取得した文章・画像は保存せず、個人化の手本にも加えません。図表・写真の内容は解釈しません。
- AIとの会話での次の依頼は、設定の「放置時に本文を生成します」の下にある「AI との会話では、次に送りそうな依頼を出す」で切り替えます（初期値はオンで、「ウィンドウの参照」が有効なときだけ働きます）。画面の文章はメモリ上だけで扱い、表示するのは生成した1文だけです。

## データの保存

設定・ユーザ辞書・個人化データは、そのMacのApp Groupコンテナに保存します。共有するグループIDは`<チームID>.dev.tomonari.inputmethod.Shizuku`です。ローカルLLMのモデルは`~/Library/Application Support/llm-ime/models/`に配置します。

入力履歴や学習データは機微な情報を含む可能性があります。リポジトリや不具合報告へ添付しないでください。

## テスト

```sh
swift test --package-path third_party/Shizuku/Core
python3 tools/dist/test_dmg_models.py
```

Coreの単体テストはモデルの重みを必要としません。入力クライアントの検査方法は[テスト](docs/testing.md)を参照してください。

## ライセンスと謝辞

ソースコードは[MIT License](LICENSE)です。Shizukuは[azooKey-Desktop](https://github.com/azooKey/azooKey-Desktop)と[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)を基にしています。第三者のコード・辞書・モデルにはそれぞれのライセンスが適用されます。[第三者ライセンス](THIRD_PARTY_NOTICES.md)を参照してください。
