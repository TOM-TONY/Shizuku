#!/bin/bash
# GitHub Actions 専用: 署名に使うものを、使い捨てのキーチェーンへ入れる（普段の Mac では実行しない）。
# release.sh と lib.sh は、ここで入れた証明書・公証の認証情報・アップデートの署名鍵をそのまま使う。
set -euo pipefail

[[ "${GITHUB_ACTIONS:-}" == "true" && -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" ]] || {
    echo "GitHub Actions の中でだけ実行できます（キーチェーンの検索順を書き換えるため）" >&2
    exit 1
}
for name in SHIZUKU_TEAM_ID DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD ASC_KEY_P8_BASE64 ASC_KEY_ID \
            ASC_ISSUER_ID UPDATE_SIGNING_KEY UPDATE_PUBLIC_KEY; do
    [[ -n "${!name:-}" ]] || { echo "$name が設定されていません（docs/release.md を参照）" >&2; exit 1; }
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
secrets_dir="$RUNNER_TEMP/shizuku-signing"
keychain="$secrets_dir/signing.keychain-db"
mkdir -p "$secrets_dir"
chmod 700 "$secrets_dir"

# 署名鍵が違うと、配った管理アプリが新しい版を受け付けなくなる。先に公開鍵で確かめる
swiftc -O "$root/tools/dist/update_key.swift" -o "$secrets_dir/update_key"
actual_public_key="$(printf '%s' "$UPDATE_SIGNING_KEY" | "$secrets_dir/update_key" public)"
[[ "$actual_public_key" == "$UPDATE_PUBLIC_KEY" ]] || {
    echo "アップデートの署名鍵が UPDATE_PUBLIC_KEY と一致しません" >&2
    exit 1
}

keychain_password="$(uuidgen)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
security default-keychain -d user -s "$keychain"

printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -D > "$secrets_dir/developer-id.p12"
security import "$secrets_dir/developer-id.p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -f pkcs12 \
    -T /usr/bin/codesign -T /usr/bin/security > /dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
rm -f "$secrets_dir/developer-id.p12"

printf '%s' "$ASC_KEY_P8_BASE64" | base64 -D > "$secrets_dir/AuthKey.p8"
chmod 600 "$secrets_dir/AuthKey.p8"
xcrun notarytool store-credentials "${NOTARY_PROFILE:-llm-ime-notary}" --key "$secrets_dir/AuthKey.p8" \
    --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --keychain "$keychain" > /dev/null

# lib.sh の signing_key が読む場所（なければ新しい鍵を作ってしまうので、必ず先に入れる）
security add-generic-password -s "dev.tomonari.llm-ime.update-signing" -a "ed25519" -l "update signing key" \
    -w "$UPDATE_SIGNING_KEY" -T /usr/bin/security "$keychain"

# Developer ID のプロファイルを xcodebuild が取りに行くための認証（lib.sh の build_ime が使う）
echo "XCODE_AUTH_ARGS=-authenticationKeyPath $secrets_dir/AuthKey.p8 -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID" >> "$GITHUB_ENV"
echo "署名の準備ができました"
