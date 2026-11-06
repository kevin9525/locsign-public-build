#!/usr/bin/env python3
"""Assemble one unsigned device app as an IPA, retaining Unix file metadata."""
import argparse
import os
import pathlib
import plistlib
import stat
import tempfile
import zipfile


def assemble(products: pathlib.Path, output: pathlib.Path) -> pathlib.Path:
    apps = sorted(p for p in products.glob("*.app") if p.is_dir())
    if len(apps) != 1:
        raise ValueError(f"Expected one device app, found {len(apps)} in {products}")
    app = apps[0]
    with (app / "Info.plist").open("rb") as file:
        metadata = plistlib.load(file)
    executable = metadata.get("CFBundleExecutable", "")
    if not executable or pathlib.Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("App has no valid CFBundleExecutable")
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix="ipa-", suffix=".tmp", dir=output.parent)
    os.close(fd)
    temporary = pathlib.Path(name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            paths = [app]
            for current, directories, files in os.walk(app, followlinks=False):
                paths.extend(pathlib.Path(current) / part for part in sorted(directories + files))
            for path in paths:
                relative = pathlib.PurePosixPath("Payload", app.name, *path.relative_to(app).parts).as_posix()
                mode = path.lstat().st_mode
                if stat.S_ISLNK(mode):
                    info = zipfile.ZipInfo(relative)
                    info.create_system = 3
                    info.external_attr = mode << 16
                    archive.writestr(info, os.readlink(path).encode("utf-8"))
                else:
                    archive.write(path, relative)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError("IPA archive verification failed")
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=pathlib.Path, default=pathlib.Path("build/Build/Products/Release-iphoneos"))
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("build/LocSign.ipa"))
    args = parser.parse_args()
    print(assemble(args.products, args.output))
