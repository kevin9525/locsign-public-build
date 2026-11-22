#!/usr/bin/env python3
"""Check the App icon source set and, optionally, the compiled icon inside an unsigned IPA."""
import argparse
import json
import pathlib
import plistlib
import struct
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
ICON_NAME = "AppIcon"
ICON_SET = pathlib.Path("App/Resources/Assets.xcassets") / f"{ICON_NAME}.appiconset"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_header(data: bytes):
    """Return (width, height, color_type) from a PNG IHDR chunk."""
    if len(data) < 33 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        raise ValueError("not a PNG file")
    width, height, _depth, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, color_type


def check_source(root: pathlib.Path = ROOT) -> pathlib.Path:
    """Require a single 1024x1024 opaque iOS icon referenced by Contents.json."""
    icon_set = root / ICON_SET
    contents = json.loads((icon_set / "Contents.json").read_text(encoding="utf-8"))
    images = [i for i in contents.get("images", []) if i.get("filename")]
    if len(images) != 1:
        raise ValueError(f"{ICON_SET} must reference exactly one icon file")
    image = images[0]
    if image.get("size") != "1024x1024" or image.get("idiom") != "universal" or image.get("platform") != "ios":
        raise ValueError("icon entry must be universal iOS 1024x1024")
    path = icon_set / image["filename"]
    if path.parent != icon_set or not path.is_file():
        raise ValueError(f"icon file missing: {image['filename']}")
    width, height, color_type = png_header(path.read_bytes())
    if (width, height) != (1024, 1024):
        raise ValueError(f"icon must be 1024x1024, got {width}x{height}")
    if color_type not in (0, 2):  # greyscale / truecolor without alpha
        raise ValueError("icon must be opaque (no alpha channel)")
    project = (root / "project.yml").read_text(encoding="utf-8")
    if f"ASSETCATALOG_COMPILER_APPICON_NAME: {ICON_NAME}" not in project:
        raise ValueError("project.yml does not select the AppIcon asset")
    return path


def check_ipa(ipa: pathlib.Path) -> str:
    """Require the compiled asset catalog and the primary icon name in the IPA's top-level app."""
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        plists = [n for n in names if n.count("/") == 2 and n.startswith("Payload/") and n.endswith(".app/Info.plist")]
        if len(plists) != 1:
            raise ValueError("IPA must contain exactly one top-level app Info.plist")
        app = plists[0][: -len("Info.plist")]
        if app + "Assets.car" not in names:
            raise ValueError("compiled asset catalog Assets.car is missing")
        info = plistlib.loads(archive.read(plists[0]))
    primary = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
    if primary.get("CFBundleIconName") != ICON_NAME:
        raise ValueError("Info.plist does not declare CFBundleIconName AppIcon")
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=pathlib.Path, help="also check a built IPA")
    args = parser.parse_args()
    try:
        print("icon source ok:", check_source())
        if args.ipa:
            print("icon in IPA ok:", check_ipa(args.ipa))
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"icon check failed: {error}", file=sys.stderr)
        sys.exit(1)
