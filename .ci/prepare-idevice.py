#!/usr/bin/env python3
"""Prepare checksum-pinned idevice and iOS 18 DDI assets; no device connection."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import tempfile
import urllib.request
import zipfile

ARCHIVE_URL = "https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-xcframework-v0.1.68.zip"
ARCHIVE_SIZE = 213480984
ARCHIVE_SHA256 = "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"
DDI_REVISION = "fc0dcfc99cdfd6973e4a2e01c6e75ed01b1e6171"
DDI_BASE = f"https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/{DDI_REVISION}/PersonalizedImages/Xcode_iOS_DDI_Personalized/"
DDI_FILES = {
    "BuildManifest.plist": (1428695, "7fd2559e871556d3d09891ffb0e5d28dab5a1ffa57f8c3e7192de5651be3bc97"),
    "Image.dmg": (9685392, "a3ae9b9468f622ae01ab9415300c674a2ebf67b7f92d7d117392dea4ba452ab8"),
    "Image.dmg.trustcache": (1059, "8a95d27ca915b3c839227180f1028088f6dc40cdadafb3307e733f65c7f2e099"),
}


def verified(path, size, digest):
    if not path.is_file() or path.stat().st_size != size:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == digest


def write_verified(stream, destination, size, digest):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    hasher, count = hashlib.sha256(), 0
    try:
        with temporary.open("wb") as out:
            while chunk := stream.read(min(1024 * 1024, size - count + 1)):
                count += len(chunk)
                if count > size:
                    raise ValueError("Downloaded asset exceeds its pinned length")
                hasher.update(chunk)
                out.write(chunk)
        if count != size or hasher.hexdigest() != digest:
            raise ValueError("Downloaded asset length or SHA256 does not match the pinned release")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def download(url, destination, size, digest):
    if verified(destination, size, digest):
        return
    if not url.startswith("https://"):
        raise ValueError("Dependency downloads require HTTPS")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                if not response.geturl().startswith("https://"):
                    raise ValueError("Insecure dependency redirect")
                write_verified(response, destination, size, digest)
            return
        except (OSError, ValueError):
            if attempt == 2:
                raise


def extract_framework(archive, destination):
    prefix = PurePosixPath("swift/IDevice.xcframework")
    with zipfile.ZipFile(archive) as z:
        members = []
        total = 0
        for info in z.infolist():
            path = PurePosixPath(info.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in info.filename or ":" in info.filename:
                raise ValueError("Unsafe archive path")
            if path != prefix and prefix not in path.parents:
                raise ValueError("Unexpected content outside IDevice.xcframework")
            if stat.S_ISLNK(info.external_attr >> 16):
                raise ValueError("Dependency archive must not contain symlinks")
            total += info.file_size
            if total > 1500 * 1024 * 1024:
                raise ValueError("Expanded dependency archive is too large")
            members.append(info)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent) as scratch:
            z.extractall(scratch, members=members)
            source = Path(scratch) / prefix
            metadata = plistlib.loads((source / "Info.plist").read_bytes())
            slices = {row["LibraryIdentifier"] for row in metadata["AvailableLibraries"]}
            if not {"ios-arm64", "ios-arm64_x86_64-simulator"}.issubset(slices):
                raise ValueError("Release is missing required device or simulator slices")
            if destination.exists():
                shutil.rmtree(destination)
            shutil.move(str(source), destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "build" / "idevice")
    parser.add_argument("--archive", type=Path, help="Use an already-downloaded archive (still checksum checked)")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.archive or args.output / "idevice-v0.1.68.zip"
    if args.archive:
        if not verified(archive, ARCHIVE_SIZE, ARCHIVE_SHA256):
            raise ValueError("Local idevice archive failed verification")
    else:
        download(ARCHIVE_URL, archive, ARCHIVE_SIZE, ARCHIVE_SHA256)
    extract_framework(archive, args.output / "IDevice.xcframework")
    for name, (size, digest) in DDI_FILES.items():
        download(DDI_BASE + name, args.output / "LocationDDI" / name, size, digest)
    print("Verified idevice v0.1.68 and DDI 16E5121h in", args.output)


if __name__ == "__main__":
    main()
