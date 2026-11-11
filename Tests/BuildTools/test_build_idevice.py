import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE = Path(__file__).parents[2] / ".ci" / "build-idevice.py"


class BuildIdeviceTests(unittest.TestCase):
    def test_tls_patch_rejects_changed_upstream_before_modifying_source(self):
        spec = importlib.util.spec_from_file_location("build_idevice", MODULE)
        build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(build)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "idevice/src/sni.rs"
            source.parent.mkdir(parents=True)
            original = b"// Unexpected upstream TLS verifier\n"
            source.write_bytes(original)
            with self.assertRaisesRegex(ValueError, "Pinned TLS verifier changed"):
                build.patch_tls_verifier(root)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(list(source.parent.iterdir()), [source])


if __name__ == "__main__":
    unittest.main()
