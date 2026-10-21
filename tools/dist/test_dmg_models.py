import json
from pathlib import Path
import tempfile
import unittest

import dmg_models


class DMGModelsTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.payload = Path(self.work.name)
        self.models = self.payload / "models"
        self.embedding = self.models / dmg_models.EMBEDDING_MODEL
        (self.embedding / "embedder.mlmodelc").mkdir(parents=True)
        (self.embedding / "embedder.mlmodelc/weights.bin").write_bytes(b"weights")
        (self.embedding / "tokenizer.json").write_text("{}")
        self.info = {"source": dmg_models.EMBEDDING_SOURCE, "license": "apache-2.0"}
        self.write_info()
        (self.models / "gemma4-e2b-ane").mkdir()

    def write_info(self):
        (self.embedding / "embedding.json").write_text(json.dumps(self.info))

    def test_required_model_is_added_to_override_once(self):
        self.assertEqual(dmg_models.validate(self.models, ["gemma4-e2b-ane"]),
                         ["gemma4-e2b-ane", dmg_models.EMBEDDING_MODEL])
        self.assertEqual(dmg_models.validate(self.models, [dmg_models.EMBEDDING_MODEL] * 2),
                         [dmg_models.EMBEDDING_MODEL])

    def test_manifest_marks_required_and_counts_nested_files(self):
        dmg_models.write_manifest(self.payload, "test", ["gemma4-e2b-ane"])
        manifest = json.loads((self.payload / "manifest.json").read_text())
        self.assertEqual(manifest["version"], "test")
        optional, required = manifest["models"]
        self.assertFalse(optional["required"])
        self.assertEqual(optional["recommendedMemoryGB"], 8)
        self.assertTrue(required["required"])
        self.assertEqual(required["name"], dmg_models.EMBEDDING_MODEL)
        self.assertEqual(required["bytes"], sum(p.stat().st_size for p in self.embedding.rglob("*") if p.is_file()))

    def test_missing_files_fail(self):
        for relative in ("embedding.json", "tokenizer.json", "embedder.mlmodelc/weights.bin"):
            with self.subTest(file=relative):
                path = self.embedding / relative
                data = path.read_bytes()
                path.unlink()
                with self.assertRaises(ValueError):
                    dmg_models.validate(self.models, [])
                path.write_bytes(data)

    def test_empty_files_fail(self):
        for relative in ("embedding.json", "tokenizer.json", "embedder.mlmodelc/weights.bin"):
            with self.subTest(file=relative):
                path = self.embedding / relative
                data = path.read_bytes()
                path.write_bytes(b"")
                with self.assertRaises(ValueError):
                    dmg_models.validate(self.models, [])
                path.write_bytes(data)

    def test_missing_or_inconsistent_source_and_license_fail(self):
        for key in ("source", "license"):
            for value in (None, "", "unexpected"):
                with self.subTest(key=key, value=value):
                    saved = self.info.pop(key)
                    if value is not None:
                        self.info[key] = value
                    self.write_info()
                    with self.assertRaises(ValueError):
                        dmg_models.validate(self.models, [])
                    self.info[key] = saved

    def test_malformed_metadata_fails(self):
        for content in ("{", "null", "[]"):
            with self.subTest(content=content):
                (self.embedding / "embedding.json").write_text(content)
                with self.assertRaises(ValueError):
                    dmg_models.validate(self.models, [])

    def test_unknown_or_missing_optional_model_fails(self):
        for name in ("../other", "gemma4-e4b-ane"):
            with self.subTest(model=name), self.assertRaises(ValueError):
                dmg_models.validate(self.models, [name])

    def test_bundle_manifest_hashes_all_model_files(self):
        dmg_models.write_manifest(self.payload, "new", [], include_hashes=True)
        model = json.loads((self.payload / "manifest.json").read_text())["models"][0]
        self.assertEqual(set(model["sha256"]), {"embedding.json", "tokenizer.json", "embedder.mlmodelc/weights.bin"})
        self.assertEqual(model["sha256"]["tokenizer.json"], dmg_models.sha256(self.embedding / "tokenizer.json"))

    def test_dmg_manifest_references_bundle_without_duplicate(self):
        other = self.payload / "dmg-payload"
        (other / "models/gemma4-e2b-ane").mkdir(parents=True)
        dmg_models.write_manifest(other, "new", ["gemma4-e2b-ane"], bundled_payload=self.payload)
        model = json.loads((other / "manifest.json").read_text())["models"][1]
        self.assertTrue(model["required"] and model["bundled"])
        self.assertGreater(model["bytes"], 0)
        self.assertFalse((other / "models" / dmg_models.EMBEDDING_MODEL).exists())

    def test_symlink_is_rejected_before_bundling(self):
        (self.embedding / "external").symlink_to(self.models / "gemma4-e2b-ane")
        with self.assertRaises(ValueError):
            dmg_models.validate(self.models, [])


if __name__ == "__main__":
    unittest.main()
