import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import zipfile

MODULE = pathlib.Path(__file__).parents[2] / ".ci" / "make-ipa.py"
spec = importlib.util.spec_from_file_location("make_ipa", MODULE)
make_ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_ipa)


class MakeIPATests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.products = self.root / "products"
        self.products.mkdir()
        self.output = self.root / "out" / "LocSign.ipa"

    def app(self, name="LocSign"):
        app = self.products / (name + ".app")
        app.mkdir()
        (app / name).write_bytes(b"test executable")
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name}))
        return app

    def test_archive_has_payload_and_preserves_executable_bytes(self):
        app = self.app()
        (app / "empty").mkdir()
        make_ipa.assemble(self.products, self.output)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read("Payload/LocSign.app/LocSign"), b"test executable")
            self.assertIn("Payload/LocSign.app/empty/", archive.namelist())
            self.assertTrue(all(name.startswith("Payload/") for name in archive.namelist()))

    def test_multiple_apps_are_rejected_instead_of_picking_first(self):
        self.app("One")
        self.app("Two")
        with self.assertRaises(ValueError):
            make_ipa.assemble(self.products, self.output)
        self.assertFalse(self.output.exists())

    def test_missing_executable_is_rejected(self):
        app = self.app()
        (app / "LocSign").unlink()
        with self.assertRaises(ValueError):
            make_ipa.assemble(self.products, self.output)
        self.assertFalse(self.output.exists())

    def test_rebuild_replaces_old_archive_without_stale_members(self):
        app = self.app()
        stale = app / "stale.txt"
        stale.write_text("old")
        make_ipa.assemble(self.products, self.output)
        stale.unlink()
        make_ipa.assemble(self.products, self.output)
        with zipfile.ZipFile(self.output) as archive:
            self.assertNotIn("Payload/LocSign.app/stale.txt", archive.namelist())


if __name__ == "__main__":
    unittest.main()
