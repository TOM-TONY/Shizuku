#!/bin/bash
# GitHub Actions 専用: ci_prepare.sh が作った使い捨てのキーチェーンと鍵を消す。
set -uo pipefail

[[ "${GITHUB_ACTIONS:-}" == "true" && -n "${RUNNER_TEMP:-}" ]] || {
    echo "GitHub Actions の中でだけ実行できます" >&2
    exit 1
}
secrets_dir="$RUNNER_TEMP/shizuku-signing"
security delete-keychain "$secrets_dir/signing.keychain-db" 2>/dev/null
rm -rf "$secrets_dir"
exit 0
