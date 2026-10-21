"""DMG のモデルの確認と manifest の作成（重みの読み込み・取得はしない）。"""

import json
import hashlib
from pathlib import Path
import sys


EMBEDDING_MODEL = "ruri-v3-30m-coreml"
EMBEDDING_SOURCE = "cl-nagoya/ruri-v3-30m@24899e5de370b56d179604a007c0d727bf144504"
INFO = {
    "gemma4-e4b-ane": ("続きの予測（標準・Gemma 4 E4B）", "入力中・手を止めたときに続きを灰色で表示します。ANE（ニューラルエンジン）で動きます。", 16),
    "gemma4-e2b-ane": ("続きの予測（省電力・Gemma 4 E2B）", "標準より軽く、精度は少し下がります。設定の「省電力」で使います。", 8),
    "gemma4-12b-it-mlx": ("いい感じ変換・添削・書き直し（Gemma 4 12B）", "GPU で動きます。使うときに約 11 GB のメモリを使います。", 24),
    "gemma4-31b-it-mlx": ("いい感じ変換・添削・書き直し（高精度・Gemma 4 31B）", "より正確ですが、約 22 GB のメモリを使います（メモリ 64 GB 以上の Mac 向け）。", 64),
    EMBEDDING_MODEL: ("解析と学習（文の埋め込み・Ruri v3 30M）", "過去の文章の意味検索と話題の解析に使います。メモリの量にかかわらず必ず入ります。", 0),
}


def validate(directory, names, embedding_directory=None):
    names = list(dict.fromkeys([*names, EMBEDDING_MODEL]))
    for name in names:
        if name not in INFO:
            raise ValueError(f"配布用のモデルの説明がありません: {name}")
        location = embedding_directory if name == EMBEDDING_MODEL and embedding_directory else directory / name
        if not location.is_dir():
            raise ValueError(f"モデルのフォルダがありません: {directory / name}")
    embedding = embedding_directory or directory / EMBEDDING_MODEL
    if embedding.is_symlink() or any(p.is_symlink() for p in embedding.rglob("*")):
        raise ValueError("埋め込みモデルにシンボリックリンクは同梱できません")
    for name in ("embedding.json", "tokenizer.json"):
        if not (embedding / name).is_file() or (embedding / name).stat().st_size == 0:
            raise ValueError(f"埋め込みモデルのファイルがありません（または空です）: {embedding / name}")
    compiled = embedding / "embedder.mlmodelc"
    if not compiled.is_dir() or not any(p.is_file() and p.stat().st_size for p in compiled.rglob("*")):
        raise ValueError(f"埋め込みモデルのコンパイル済みフォルダがありません（または空です）: {compiled}")
    info = json.loads((embedding / "embedding.json").read_text(encoding="utf-8"))
    if not isinstance(info, dict) or info.get("source") != EMBEDDING_SOURCE or info.get("license") != "apache-2.0":
        raise ValueError("embedding.json の source・license が同梱の出典・ライセンスと一致しません")
    return names


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_manifest(payload, version, names, bundled_payload=None, include_hashes=False):
    directory = payload / "models"
    embedding = bundled_payload / "models" / EMBEDDING_MODEL if bundled_payload else None
    models = []
    for name in validate(directory, names, embedding):
        title, detail, memory = INFO[name]
        model_directory = embedding if name == EMBEDDING_MODEL and embedding else directory / name
        model = {
            "name": name, "title": title, "detail": detail, "recommendedMemoryGB": memory,
            "required": name == EMBEDDING_MODEL,
            "bytes": sum(p.stat().st_size for p in model_directory.rglob("*") if p.is_file()),
        }
        if name == EMBEDDING_MODEL and (include_hashes or bundled_payload):
            model["sha256"] = {str(p.relative_to(model_directory)): sha256(p)
                               for p in sorted(model_directory.rglob("*")) if p.is_file()}
        if name == EMBEDDING_MODEL and bundled_payload:
            model["bundled"] = True
        models.append(model)
    (payload / "manifest.json").write_text(
        json.dumps({"version": version, "models": models}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    try:
        if len(sys.argv) >= 3 and sys.argv[1] == "validate":
            print(" ".join(validate(Path(sys.argv[2]), sys.argv[3:])))
        elif len(sys.argv) >= 4 and sys.argv[1] == "manifest":
            write_manifest(Path(sys.argv[2]), sys.argv[3], sys.argv[4:])
        elif len(sys.argv) >= 4 and sys.argv[1] == "bundle-manifest":
            write_manifest(Path(sys.argv[2]), sys.argv[3], [EMBEDDING_MODEL], include_hashes=True)
        elif len(sys.argv) >= 5 and sys.argv[1] == "dmg-manifest":
            write_manifest(Path(sys.argv[2]), sys.argv[3], sys.argv[5:], bundled_payload=Path(sys.argv[4]))
        else:
            sys.exit("usage: dmg_models.py validate MODEL_DIR [MODEL…] | manifest PAYLOAD VERSION [MODEL…]")
    except (OSError, ValueError) as error:
        sys.exit(f"モデルを同梱できません: {error}")
