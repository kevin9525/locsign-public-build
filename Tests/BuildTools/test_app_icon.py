import importlib.util
import pathlib
import plistlib
import shutil
import struct
import tempfile
import unittest
import zipfile
import zlib

MODULE = pathlib.Path(__file__).parents[2] / ".ci" / "verify-app-icon.py"
spec = importlib.util.spec_from_file_location("verify_app_icon", MODULE)
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def png(width, height, color_type=2):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return verify.PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IEND", b"")


class RepositoryIconTests(unittest.TestCase):
    def test_repository_icon_is_opaque_1024_and_selected(self):
        path = verify.check_source()
        self.assertEqual(path.name, "AppIcon-1024.png")


class SourceIconTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        real = verify.ROOT
        shutil.copytree(real / verify.ICON_SET, self.root / verify.ICON_SET)
        shutil.copy(real / "project.yml", self.root / "project.yml")
        self.icon = self.root / verify.ICON_SET / "AppIcon-1024.png"

    def test_alpha_icon_is_rejected(self):
        self.icon.write_bytes(png(1024, 1024, color_type=6))
        with self.assertRaises(ValueError):
            verify.check_source(self.root)

    def test_wrong_size_is_rejected(self):
        self.icon.write_bytes(png(512, 512))
        with self.assertRaises(ValueError):
            verify.check_source(self.root)

    def test_unselected_icon_is_rejected(self):
        project = self.root / "project.yml"
        project.write_text(project.read_text(encoding="utf-8").replace("ASSETCATALOG_COMPILER_APPICON_NAME", "X_"), encoding="utf-8")
        with self.assertRaises(ValueError):
            verify.check_source(self.root)


class IPAIconTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ipa = pathlib.Path(self.temp.name) / "LocSign.ipa"

    def build(self, info, with_car=True):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/LocSign.app/Info.plist", plistlib.dumps(info))
            if with_car:
                archive.writestr("Payload/LocSign.app/Assets.car", b"car")

    def test_compiled_icon_is_accepted(self):
        self.build({"CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}}})
        self.assertEqual(verify.check_ipa(self.ipa), "Payload/LocSign.app/")

    def test_missing_icon_declaration_is_rejected(self):
        self.build({"CFBundleExecutable": "LocSign"})
        with self.assertRaises(ValueError):
            verify.check_ipa(self.ipa)

    def test_missing_asset_catalog_is_rejected(self):
        self.build({"CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}}}, with_car=False)
        with self.assertRaises(ValueError):
            verify.check_ipa(self.ipa)


if __name__ == "__main__":
    unittest.main()
