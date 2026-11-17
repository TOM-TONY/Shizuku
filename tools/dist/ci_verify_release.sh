#!/bin/bash
# 公開した update.json を、管理アプリと同じ URL から読み直し、今回作った版と同じか確かめる。
#   ci_verify_release.sh [この版の update.json]（省略時は build/release の最新）
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tools/dist/release.conf"
[[ -n "${REPO:-}" ]] || { echo "tools/dist/release.conf の REPO が空です" >&2; exit 1; }

local_info="${1:-$(ls -t "$root"/build/release/*/update.json | head -1)}"
published="$(mktemp)"
trap 'rm -f "$published"' EXIT
base="${SHIZUKU_RELEASE_BASE_URL:-https://github.com/$REPO/releases/latest/download}"
curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors "$base/update.json" -o "$published"

python3 - "$local_info" "$published" <<'EOF'
import json
import sys

local, published = (json.load(open(path)) for path in sys.argv[1:])
for key in ("version", "build", "url", "size", "sha256", "signature"):
    if local.get(key) != published.get(key):
        sys.exit(f"公開された update.json の {key} が今回の版と違います")
print(f"配信を確認しました: {published['version']}（{published['build']}）")
EOF
