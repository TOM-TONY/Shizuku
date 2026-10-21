# llm-ime: 配布用のビルドの共通部分（make_dmg.sh と release.sh から source する）
#
# 公証には、キーチェーンに保存した notarytool の認証情報（既定の名前 llm-ime-notary）を使う:
#   xcrun notarytool store-credentials "llm-ime-notary" --apple-id <Apple ID> --team-id YOURTEAMID
# アップデートの署名鍵（Ed25519）はログインキーチェーンの汎用パスワード（KEY_SERVICE）に置く。
# 初めて使うときに作る。なくすと、配った管理アプリがそれ以降のアップデートを受け付けないので、控えを取っておくこと。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IME="$ROOT/third_party/Shizuku"
TEAM="${SHIZUKU_TEAM_ID:?Set SHIZUKU_TEAM_ID to your Apple Developer team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-llm-ime-notary}"
KEY_SERVICE="dev.tomonari.llm-ime.update-signing"
KEY_ACCOUNT="ed25519"
MANAGER_NAME="Shizuku.app"
MODEL_DIR="$HOME/Library/Application Support/llm-ime/models"
[[ -f "$ROOT/tools/dist/release.conf" ]] && source "$ROOT/tools/dist/release.conf"

# 署名に使う証明書。DEV=true なら Apple Development（この Mac で試す用。公証しない）
setup_identity() {
    if $DEV; then
        IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
    else
        IDENTITY="$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM)\)\"/\1/p" | head -1)"
        if [[ -z "$IDENTITY" ]]; then
            echo "Developer ID Application の証明書が見つかりません（Xcode → 設定 → Accounts → Manage Certificates で作る）" >&2
            exit 1
        fi
        if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
            echo "公証の認証情報 $NOTARY_PROFILE が見つかりません（xcrun notarytool store-credentials で保存する）" >&2
            exit 1
        fi
    fi
    echo "署名: $IDENTITY"
}

# 公証してから staple し、Gatekeeper が受け入れるか確かめる（DEV では何もしない）
notarize() {  # $1: .app
    $DEV && return 0
    local zip
    zip="$(dirname "$1")/$(basename "$1" .app)-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$1" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$1"
    rm -f "$zip"
    local verdict
    verdict="$(spctl -a -t exec -vv "$1" 2>&1 || true)"
    echo "$verdict"
    [[ "$verdict" == *"accepted"* ]] || { echo "Gatekeeper に拒否された: $1" >&2; exit 1; }
}

# 署名鍵の秘密鍵（base64）。なければ作ってキーチェーンに保存する
signing_key() {
    local key
    if ! key="$(security find-generic-password -s "$KEY_SERVICE" -a "$KEY_ACCOUNT" -w 2>/dev/null)"; then
        echo "アップデートの署名鍵を作ってキーチェーンに保存します（${KEY_SERVICE}）" >&2
        key="$("$UPDATE_KEY" generate | python3 -c 'import json,sys; print(json.load(sys.stdin)["private"])')"
        security add-generic-password -s "$KEY_SERVICE" -a "$KEY_ACCOUNT" -l "llm-ime update signing key" -w "$key" >/dev/null
    fi
    printf '%s' "$key"
}

build_update_key_tool() {  # $1: 出力先ディレクトリ
    UPDATE_KEY="$1/update_key"
    swiftc -O -target arm64-apple-macos15.0 "$ROOT/tools/dist/update_key.swift" -o "$UPDATE_KEY"
}

# IME 本体を archive・書き出し・署名・公証する → $OUT/ime/Shizuku.app
build_ime() {  # $1: OUT, $2: VERSION, $3: BUILD
    local out="$1" version="$2" build="$3"
    echo "== IME 本体をビルド（$version / ${build}）"
    xcodebuild -project "$IME/Shizuku.xcodeproj" -scheme Shizuku -configuration Release \
        archive -archivePath "$out/Shizuku.xcarchive" \
        -derivedDataPath "$IME/build/dd-dist" -clonedSourcePackagesDirPath "$IME/build/dd-signed/SourcePackages" \
        -destination "generic/platform=macOS" ARCHS=arm64 \
        DEVELOPMENT_TEAM="$TEAM" MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
        -allowProvisioningUpdates > "$out/archive.log" 2>&1 || { tail -30 "$out/archive.log"; exit 1; }
    # 管理アプリも Shizuku.app なので、別のディレクトリに置く。
    local app="$out/ime/Shizuku.app"
    mkdir -p "$out/ime"
    if $DEV; then
        cp -R "$out/Shizuku.xcarchive/Products/Applications/Shizuku.app" "$app"
    else
        cat > "$out/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
EOF
        xcodebuild -exportArchive -archivePath "$out/Shizuku.xcarchive" -exportPath "$out/export" \
            -exportOptionsPlist "$out/exportOptions.plist" -allowProvisioningUpdates > "$out/export.log" 2>&1 \
            || { tail -30 "$out/export.log"; exit 1; }
        mv "$out/export/Shizuku.app" "$app"
        rm -rf "$out/export"
        # Xcode の書き出しは Contents/Helpers の下のリソースバンドルを署名し直さない。開発用の署名のまま残ると、
        # 公証は通っても Gatekeeper に拒否される。Developer ID で署名し直し、外側も（entitlements を保って）署名し直す
        local b
        for b in "$app/Contents/Helpers/ConverterServer"/*.bundle; do
            codesign --force --timestamp --sign "$IDENTITY" "$b"
        done
        codesign -d --entitlements - --xml "$app" > "$out/Shizuku.entitlements"
        codesign --force --timestamp --options runtime --entitlements "$out/Shizuku.entitlements" --sign "$IDENTITY" "$app"
        check_developer_id "$app"
    fi
    codesign --verify --deep --strict "$app"
    notarize "$app"
}

# 中の署名がすべて Developer ID であることを確かめる
check_developer_id() {  # $1: .app
    local sig item info
    while IFS= read -r -d '' sig; do
        item="$(dirname "$sig")"
        [[ "$(basename "$item")" == "Contents" ]] && item="$(dirname "$item")"
        # （pipefail のもとで grep -q に渡すと、途中で読むのをやめた codesign が失敗扱いになるため、いったん変数に入れる）
        info="$(codesign -dvv "$item" 2>&1)"
        if [[ "$info" != *"Authority=Developer ID Application"* ]]; then
            echo "Developer ID で署名されていない: $item" >&2
            exit 1
        fi
    done < <(find "$1" -name _CodeSignature -type d -print0)
}

# 管理アプリ（インストール・アップデート・アンインストール。IME 本体を Contents/Helpers に含む）→ $OUT/$MANAGER_NAME
build_manager() {  # $1: OUT, $2: VERSION, $3: BUILD, $4: 配信元 URL, $5: 公開鍵（base64）
    local out="$1" version="$2" build="$3" feed="$4" public_key="$5"
    echo "== 管理アプリをビルド"
    python3 "$ROOT/tools/dist/dmg_models.py" validate "$MODEL_DIR" ruri-v3-30m-coreml >/dev/null
    local app="$out/$MANAGER_NAME"
    local swift_flags=""
    if $DEV; then swift_flags="-D MANAGER_DEVELOPMENT"; fi
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
    swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
        $swift_flags "$ROOT/tools/manager/BundleSupport.swift" "$ROOT/tools/manager/BundledModels.swift" \
        "$ROOT/tools/manager/Install.swift" "$ROOT/tools/manager/Update.swift" "$ROOT/tools/manager/ManagerApp.swift" \
        -o "$app/Contents/MacOS/Manager"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.tomonari.llm-ime.manager</string>
  <key>CFBundleName</key><string>Shizuku</string>
  <key>CFBundleDisplayName</key><string>Shizuku</string>
  <key>CFBundleExecutable</key><string>Manager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>LLMIMEUpdateFeedURL</key><string>$feed</string>
  <key>LLMIMEUpdatePublicKey</key><string>$public_key</string>
  <key>LLMIMETeamID</key><string>$TEAM</string>
</dict></plist>
EOF
    ditto "$out/ime/Shizuku.app" "$app/Contents/Helpers/Shizuku.app"
    rm -rf "$out/ime"
    local payload="$app/Contents/Resources/ModelPayload"
    mkdir -p "$payload/models"
    cp -cR "$MODEL_DIR/ruri-v3-30m-coreml" "$payload/models/ruri-v3-30m-coreml"
    python3 "$ROOT/tools/dist/dmg_models.py" bundle-manifest "$payload" "$version"
    cp "$ROOT/tools/dist/ruri-v3-LICENSE.txt" "$app/Contents/Resources/ruri-v3.txt"
    cp "$ROOT/tools/dist/MODELS_NOTICE.txt" "$app/Contents/Resources/MODELS_NOTICE.txt"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$app"
    codesign --verify --deep --strict "$app"
    notarize "$app"
}
