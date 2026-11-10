import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import zipfile

MODULE = Path(__file__).parents[2] / ".ci" / "prepare-idevice.py"


class PrepareIdeviceTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(), "The pinned dependency preparer must exist")
        spec = importlib.util.spec_from_file_location("prepare_idevice", MODULE)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_verified_stream_is_written_and_bad_digest_keeps_previous_file(self):
        output = self.root / "asset"
        data = b"verified image"
        self.module.write_verified(io.BytesIO(data), output, len(data), hashlib.sha256(data).hexdigest())
        self.assertEqual(output.read_bytes(), data)
        with self.assertRaises(ValueError):
            self.module.write_verified(io.BytesIO(b"changed image!"), output, len(data), hashlib.sha256(data).hexdigest())
        self.assertEqual(output.read_bytes(), data)

    def test_oversized_and_truncated_downloads_are_rejected(self):
        for data in (b"123", b"12345"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.module.write_verified(io.BytesIO(data), self.root / "asset", 4, "0" * 64)
        self.assertFalse((self.root / "asset").exists())

    def test_archive_cannot_escape_expected_framework(self):
        for name in ("../outside", "swift/IDevice.xcframework/../../outside", "evil/file"):
            archive = self.root / "bad.zip"
            with zipfile.ZipFile(archive, "w") as z:
                z.writestr(name, b"bad")
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.module.extract_framework(archive, self.root / "out")
            self.assertFalse((self.root / "outside").exists())


if __name__ == "__main__":
    unittest.main()
