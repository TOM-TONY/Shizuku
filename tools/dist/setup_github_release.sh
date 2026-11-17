#!/bin/bash
# 配信する人が自分の Mac で 1 回だけ実行し、GitHub に release 環境と秘密情報を登録する。
# 値は標準入力で gh へ渡し、画面やコマンドラインには出さない。
#
#   tools/dist/setup_github_release.sh --team <チームID> --p12 <証明書.p12> \
#       --asc-key <AuthKey.p8> --asc-key-id <キーID> --asc-issuer <発行者ID>
#
# .p12 は Developer ID Application の証明書を秘密鍵ごと書き出したもの。パスワードは実行中に尋ねる。
set -euo pipefail

team="" p12="" asc_key="" asc_key_id="" asc_issuer=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team) team="$2"; shift ;;
        --p12) p12="$2"; shift ;;
        --asc-key) asc_key="$2"; shift ;;
        --asc-key-id) asc_key_id="$2"; shift ;;
        --asc-issuer) asc_issuer="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ -n "$team" && -f "$p12" && -f "$asc_key" && -n "$asc_key_id" && -n "$asc_issuer" ]] || {
    sed -n 5,6p "$0" >&2
    exit 2
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tools/dist/release.conf"
[[ -n "${REPO:-}" ]] || { echo "tools/dist/release.conf の REPO が空です" >&2; exit 1; }
key_service="dev.tomonari.llm-ime.update-signing"
key_account="ed25519"
security find-generic-password -s "$key_service" -a "$key_account" > /dev/null 2>&1 || {
    echo "アップデートの署名鍵がキーチェーンにありません。新しい鍵は作らずに中止します" >&2
    exit 1
}

echo "配信先: $REPO（$(gh api user --jq .login) として登録します）"
read -r -p "続けますか？ [y/N] " answer
[[ "$answer" == "y" ]] || exit 1
read -r -s -p ".p12 のパスワード: " p12_password
echo

gh api -X PUT "repos/$REPO/environments/release" --silent \
    -F "deployment_branch_policy[protected_branches]=false" -F "deployment_branch_policy[custom_branch_policies]=true"
gh api "repos/$REPO/environments/release/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main \
    || gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" --silent -f name=main

set_secret() { gh secret set "$1" --repo "$REPO" --env release > /dev/null; }
printf '%s' "$team" | set_secret SHIZUKU_TEAM_ID
base64 -i "$p12" | set_secret DEVELOPER_ID_P12_BASE64
printf '%s' "$p12_password" | set_secret DEVELOPER_ID_P12_PASSWORD
base64 -i "$asc_key" | set_secret ASC_KEY_P8_BASE64
printf '%s' "$asc_key_id" | set_secret ASC_KEY_ID
printf '%s' "$asc_issuer" | set_secret ASC_ISSUER_ID
security find-generic-password -s "$key_service" -a "$key_account" -w | set_secret UPDATE_SIGNING_KEY

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O "$root/tools/dist/update_key.swift" -o "$work/update_key"
security find-generic-password -s "$key_service" -a "$key_account" -w | "$work/update_key" public \
    | gh variable set UPDATE_PUBLIC_KEY --repo "$REPO" > /dev/null
echo "登録しました: release 環境（main からだけ使える）の秘密情報と UPDATE_PUBLIC_KEY"
