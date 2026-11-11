#!/usr/bin/env python3
"""Build pinned idevice with pairing TLS checks and bounded FFI; requires macOS/Xcode/Rust."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import tarfile

spec = importlib.util.spec_from_file_location("prepare_idevice", Path(__file__).with_name("prepare-idevice.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

REVISION = "d32c8189c51c2789496b0768039419c3705498c3"
SOURCE_URL = f"https://codeload.github.com/jkcoxson/idevice/tar.gz/{REVISION}"
SOURCE_SIZE = 686115
SOURCE_SHA256 = "882282f8b64c3908f28c2d42a556fcf92102ee982d8be3b8b5b448a02572d731"
FEATURES = "ring,tcp,tunnel_tcp_stack,dvt,location_simulation,mobile_image_mounter,tss"
TOOLCHAIN = "1.94.0"
TARGETS = ["aarch64-apple-ios", "x86_64-apple-ios", "aarch64-apple-ios-sim"]
SNI_SOURCE_SHA256 = "87c21b18d2ef2e7ad0b5ea5598714db29a1b144289530a3440d88ddd3baa992f"
TLS_FIXTURES = (
    "pairing-empty-device.der", "pairing-empty-expired.der", "pairing-empty-device-key.der",
    "pairing-empty-root.der", "pairing-host-cert.der", "pairing-host-key.der",
)

# These wrappers await timeout INSIDE the runtime. The native owner is blocked
# until the future has been dropped; no detached timeout can race handle free.
TIMEOUT_MODULE = r'''
use crate::{run_sync, run_sync_local};
use idevice::IdeviceError;
use std::{future::Future, time::Duration};

async fn bounded<T>(future: impl Future<Output = Result<T, IdeviceError>>, duration: Duration)
    -> Result<T, IdeviceError>
{
    tokio::time::timeout(duration, future).await.map_err(|_| IdeviceError::Timeout)?
}

pub(crate) fn run_sync_timeout<F, T>(future: F) -> Result<T, IdeviceError>
where F: Future<Output = Result<T, IdeviceError>> + Send + 'static, T: Send + 'static
{
    run_sync(async move { bounded(future, Duration::from_secs(30)).await })
}

pub(crate) fn run_sync_local_timeout<F, T>(future: F) -> Result<T, IdeviceError>
where F: Future<Output = Result<T, IdeviceError>>, T: 'static
{
    run_sync_local(async move { bounded(future, Duration::from_secs(30)).await })
}

pub(crate) fn run_sync_local_mount_timeout<F, T>(future: F) -> Result<T, IdeviceError>
where F: Future<Output = Result<T, IdeviceError>>, T: 'static
{
    run_sync_local(async move { bounded(future, Duration::from_secs(120)).await })
}

#[cfg(test)]
mod locsign_timeout_tests {
    use super::*;
    use std::{pin::Pin, sync::{Arc, atomic::{AtomicBool, AtomicUsize, Ordering}}};
    use idevice::{Idevice, pairing_file::PairingFile, provider::IdeviceProvider};
    use crate::provider::{IdeviceProviderHandle, idevice_provider_free};

    struct DropMarker(Arc<AtomicBool>);
    impl Drop for DropMarker { fn drop(&mut self) { self.0.store(true, Ordering::SeqCst); } }

    #[test]
    fn local_timeout_drops_borrowed_future_before_return() {
        let dropped = Arc::new(AtomicBool::new(false));
        let marker = DropMarker(dropped.clone());
        let result: Result<(), IdeviceError> = run_sync_local(async {
            bounded(async move { let _marker = marker; std::future::pending().await }, Duration::from_millis(20)).await
        });
        assert!(matches!(result, Err(IdeviceError::Timeout)));
        assert!(dropped.load(Ordering::SeqCst));
    }

    #[test]
    fn spawned_timeout_drops_future_before_ffi_returns() {
        let dropped = Arc::new(AtomicBool::new(false));
        let marker = DropMarker(dropped.clone());
        let result: Result<(), IdeviceError> = run_sync(async move {
            bounded(async move { let _marker = marker; std::future::pending().await }, Duration::from_millis(20)).await
        });
        assert!(matches!(result, Err(IdeviceError::Timeout)));
        assert!(dropped.load(Ordering::SeqCst));
    }

    #[test]
    fn completed_value_and_device_error_are_preserved() {
        assert_eq!(run_sync_timeout(async { Ok(42) }).unwrap(), 42);
        let result: Result<(), IdeviceError> = run_sync_local_timeout(async { Err(IdeviceError::NotFound) });
        assert!(matches!(result, Err(IdeviceError::NotFound)));
    }

    #[derive(Debug)]
    struct FailingProvider { drops: Arc<AtomicUsize> }

    impl Drop for FailingProvider {
        fn drop(&mut self) { self.drops.fetch_add(1, Ordering::SeqCst); }
    }

    impl IdeviceProvider for FailingProvider {
        fn connect(&self, _port: u16) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
            Box::pin(async { Err(IdeviceError::NotFound) })
        }
        fn label(&self) -> &str { "locsign-ownership-regression" }
        fn get_pairing_file(&self) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
            Box::pin(async { Err(IdeviceError::NotFound) })
        }
    }

    fn verify_failed_connect_borrows_provider<T>(
        connect: unsafe extern "C" fn(*mut IdeviceProviderHandle, *mut *mut T) -> *mut crate::IdeviceFfiError,
    ) {
        let drops = Arc::new(AtomicUsize::new(0));
        let provider = Box::into_raw(Box::new(IdeviceProviderHandle(Box::new(FailingProvider { drops: drops.clone() }))));
        let mut client = std::ptr::null_mut();
        let error = unsafe { connect(provider, &mut client) };
        assert!(!error.is_null(), "Injected connection failure must be surfaced");
        unsafe { crate::idevice_error_free(error) };
        assert!(client.is_null());
        // This assertion fails on upstream before attempting to free its dangling
        // pointer, so the regression test itself never intentionally double-frees.
        assert_eq!(drops.load(Ordering::SeqCst), 0, "A failed constructor consumed the caller's provider");
        unsafe { idevice_provider_free(provider) };
        assert_eq!(drops.load(Ordering::SeqCst), 1, "The caller must release the provider exactly once");
    }

    #[test]
    fn failed_lockdownd_connect_preserves_provider_ownership() {
        verify_failed_connect_borrows_provider(crate::lockdown::lockdownd_connect);
    }

    #[test]
    fn failed_image_mounter_connect_preserves_provider_ownership() {
        verify_failed_connect_borrows_provider(crate::mobile_image_mounter::image_mounter_connect);
    }

    #[test]
    fn failed_core_device_proxy_connect_preserves_provider_ownership() {
        verify_failed_connect_borrows_provider(crate::core_device_proxy::core_device_proxy_connect);
    }
}
'''


def patch_tls_verifier(root):
    source = root / "idevice/src/sni.rs"
    # Match the audited upstream implementation exactly before replacing its
    # unconditional certificate AND handshake-signature assertions.
    original = source.read_text(encoding="utf-8").encode("utf-8")
    if hashlib.sha256(original).hexdigest() != SNI_SOURCE_SHA256:
        raise ValueError("Pinned TLS verifier changed")
    resources = Path(__file__).resolve().parent
    fixtures = resources.parent / "Tests/LocSignTests/Fixtures"
    verifier = (resources / "idevice-sni.rs").read_text(encoding="utf-8")
    tests = (resources / "idevice-tls-tests.rs").read_text(encoding="utf-8")
    fixture_data = {name: (fixtures / name).read_bytes() for name in TLS_FIXTURES}
    source.write_text(verifier, encoding="utf-8")
    (source.parent / "locsign_tls_tests.rs").write_text(tests, encoding="utf-8")
    target = source.parent / "locsign_tls_fixtures"
    target.mkdir(exist_ok=True)
    for name, data in fixture_data.items():
        (target / name).write_bytes(data)


def patch_source(root):
    patch_tls_verifier(root)
    module = root / "ffi/src/locsign_timeout.rs"
    module.write_text(TIMEOUT_MODULE, encoding="utf-8")
    library = root / "ffi/src/lib.rs"
    original = library.read_text(encoding="utf-8")
    marker = "pub const LOCKDOWN_PORT: u16 = 62078;"
    if original.count(marker) != 1:
        raise ValueError("Pinned FFI library shape changed")
    original = original.replace(marker, "mod locsign_timeout;\nuse locsign_timeout::{run_sync_timeout, run_sync_local_timeout, run_sync_local_mount_timeout};\n\n" + marker)
    library.write_text(original, encoding="utf-8")
    replacements = {
        "dvt/location_simulation.rs": {"run_sync": "run_sync_timeout"},
        "dvt/remote_server.rs": {"run_sync": "run_sync_timeout", "run_sync_local": "run_sync_local_timeout"},
        "rsd.rs": {"run_sync": "run_sync_timeout"},
        "lockdown.rs": {"run_sync_local": "run_sync_local_timeout"},
        "mobile_image_mounter.rs": {"run_sync_local": "run_sync_local_mount_timeout"},
        "core_device_proxy.rs": {"run_sync_local": "run_sync_local_timeout"},
    }
    for filename, names in replacements.items():
        file = root / "ffi/src" / filename
        source = file.read_text(encoding="utf-8")
        for old, new in names.items():
            source, count = re.subn(r"\b" + old + r"\b", new, source)
            if count < 2:
                raise ValueError(f"Missing expected runner calls in {filename}")
        if filename in ("lockdown.rs", "mobile_image_mounter.rs"):
            # Both constructors borrow the provider. Upstream v0.1.68 wrongly
            # frees that borrow on Err, leaving the caller with a dangling owner.
            # Match the exact branch once so a revision change cannot broaden it.
            invalid_drop = """        Err(e) => {
            let _ = unsafe { Box::from_raw(provider) };
            ffi_err!(e)
        }"""
            if source.count(invalid_drop) != 1:
                raise ValueError(f"Pinned provider-ownership error branch changed in {filename}")
            source = source.replace(invalid_drop, "        Err(e) => ffi_err!(e),")
        file.write_text(source, encoding="utf-8")
    file = root / "ffi/src/adapter.rs"
    source = file.read_text(encoding="utf-8")
    for old, new in [
        ("let res = run_sync(async move { adapter.connect(port).await });",
         "let res = crate::run_sync_timeout(async move { adapter.connect(port).await.map_err(idevice::IdeviceError::from) });"),
        ("run_sync(async move { adapter.close().await.ok() });",
         "let _ = crate::run_sync_timeout(async move { let _ = adapter.close().await; Ok(()) });"),
    ]:
        if source.count(old) != 1:
            raise ValueError("Pinned adapter implementation changed")
        source = source.replace(old, new)
    file.write_text(source, encoding="utf-8")


def extract_source(archive, destination):
    prefix = "idevice-" + REVISION
    with tarfile.open(archive) as tar:
        members = []
        for item in tar.getmembers():
            path = PurePosixPath(item.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != prefix:
                raise ValueError("Unsafe pinned source archive path")
            if item.issym() and item.name == prefix + "/idevice/README.md" and item.linkname == "../README.md":
                continue  # Materialize the one known documentation link below.
            if not (item.isfile() or item.isdir()):
                raise ValueError("Unexpected special file in source archive")
            members.append(item)
        destination.mkdir(parents=True, exist_ok=True)
        tar.extractall(destination, members=members, filter="data")
        shutil.copy2(destination / prefix / "README.md", destination / prefix / "idevice/README.md")
    return destination / prefix


def run(command, cwd, env=None):
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def write_notices(source, output, env):
    metadata = json.loads(subprocess.check_output([
        "cargo", "+" + TOOLCHAIN, "metadata", "--locked", "--format-version", "1",
        "--manifest-path", str(source / "ffi/Cargo.toml"), "--no-default-features", "--features", FEATURES,
    ], cwd=source, env=env, text=True))
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    packages = {package["id"]: package for package in metadata["packages"]}
    initial = next(key for key, value in packages.items() if value["name"] == "idevice-ffi")
    pending, used = [initial], set()
    while pending:
        key = pending.pop()
        if key in used:
            continue
        used.add(key)
        for dependency in nodes[key]["deps"]:
            if any(kind["kind"] != "dev" for kind in dependency["dep_kinds"]):
                pending.append(dependency["pkg"])
    notice = ["idevice and Rust dependency notices\n",
              "The generated C header additionally contains libplist's LGPL-2.1-or-later interface declarations. "
              "The plist implementation linked here is the MIT Rust plist_ffi crate.\n"]
    repo_root = Path(__file__).resolve().parents[1]
    notice.append((repo_root / "Vendor/idevice/LICENSE-libplist-header.txt").read_text(encoding="utf-8"))
    for key in sorted(used, key=lambda item: (packages[item]["name"], packages[item]["version"])):
        package = packages[key]
        directory = Path(package["manifest_path"]).parent
        notice.append(f"\n\n===== {package['name']} {package['version']} =====\n"
                      f"License: {package.get('license') or 'see license file'}\n"
                      f"Source: {package.get('repository') or package.get('source') or 'jkcoxson/idevice ' + REVISION}\n")
        candidates = [file for file in directory.iterdir() if file.is_file() and file.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE"))]
        license_file = package.get("license_file")
        if license_file and (directory / license_file).is_file():
            candidates.append(directory / license_file)
        for file in sorted(set(candidates)):
            notice.append("\n" + file.name + "\n" + file.read_text(encoding="utf-8", errors="replace"))
    directory = output / "LocationDDI"
    directory.mkdir(exist_ok=True)
    (directory / "ThirdPartyNotices.txt").write_text("\n".join(notice), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "build/idevice")
    parser.add_argument("--prepare-source-only", action="store_true", help="Prepare and patch sources without compiling (for review)")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "idevice-source.tar.gz"
    prepare.download(SOURCE_URL, archive, SOURCE_SIZE, SOURCE_SHA256)
    # Fresh sources on every run; Cargo target/cache remains separate.
    source_container = output / "source"
    if source_container.exists():
        shutil.rmtree(source_container)
    source = extract_source(archive, source_container)
    patch_source(source)
    if args.prepare_source_only:
        print("Prepared patched source:", source)
        return
    if platform.system() != "Darwin":
        raise RuntimeError("Production idevice build requires macOS and Xcode")
    run(["rustup", "toolchain", "install", TOOLCHAIN, "--profile", "minimal"], source)
    run(["rustup", "target", "add", "--toolchain", TOOLCHAIN, *TARGETS], source)
    run(["rustup", "component", "add", "--toolchain", TOOLCHAIN, "llvm-tools-preview"], source)
    # Apple's LLVM is older than the pinned Rust LLVM. Export native Mach-O
    # objects, rather than making the final Apple linker consume Rust LTO IR.
    env = dict(os.environ, CARGO_TARGET_DIR=str(output / "cargo-target"), CARGO_PROFILE_RELEASE_LTO="false")
    env["RUSTFLAGS"] = (env.get("RUSTFLAGS", "") + " -C embed-bitcode=no").strip()
    run(["cargo", "+" + TOOLCHAIN, "test", "--locked", "-p", "idevice", "--lib", "--no-default-features", "--features", FEATURES,
         "locsign_tls_tests", "--", "--test-threads=1"], source, env)
    run(["cargo", "+" + TOOLCHAIN, "test", "--locked", "-p", "idevice-ffi", "--lib", "--no-default-features", "--features", FEATURES,
         "locsign_timeout_tests", "--", "--test-threads=1"], source, env)
    for target in TARGETS:
        sdk = "iphoneos" if target == "aarch64-apple-ios" else "iphonesimulator"
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        target_env = dict(env, IPHONEOS_DEPLOYMENT_TARGET="17.0", BINDGEN_EXTRA_CLANG_ARGS="--sysroot=" + sdk_path)
        run(["cargo", "+" + TOOLCHAIN, "build", "--locked", "--release", "-p", "idevice-ffi", "--no-default-features", "--features", FEATURES, "--target", target], source, target_env)
    headers = output / "Headers"
    headers.mkdir(exist_ok=True)
    shutil.copy2(source / "ffi/idevice.h", headers / "idevice.h")
    (headers / "module.modulemap").write_text('module IDevice {\n  header "idevice.h"\n  export *\n}\n')
    simulator = output / "idevice-simulator.a"
    run(["lipo", "-create", "-output", str(simulator), *[str(output / "cargo-target" / t / "release/libidevice_ffi.a") for t in TARGETS[1:]]], source)
    framework = output / "IDevice.xcframework"
    if framework.exists():
        shutil.rmtree(framework)
    run(["xcodebuild", "-create-xcframework", "-library", str(output / "cargo-target" / TARGETS[0] / "release/libidevice_ffi.a"),
         "-headers", str(headers), "-library", str(simulator), "-headers", str(headers), "-output", str(framework)], source)
    # Check that the minimal feature set exports every app-facing symbol.
    sysroot = Path(subprocess.check_output(["rustc", "+" + TOOLCHAIN, "--print", "sysroot"], text=True).strip())
    compiler = subprocess.check_output(["rustc", "+" + TOOLCHAIN, "-vV"], text=True)
    host = next(line.removeprefix("host: ") for line in compiler.splitlines() if line.startswith("host: "))
    llvm_nm = sysroot / "lib/rustlib" / host / "bin/llvm-nm"
    exports = subprocess.check_output([str(llvm_nm), "--extern-only", "--defined-only", str(output / "cargo-target" / TARGETS[0] / "release/libidevice_ffi.a")], text=True)
    for name in ["location_simulation_set", "location_simulation_clear", "image_mounter_mount_personalized", "plist_free", "plist_get_uint_val", "rsd_handshake_new", "core_device_proxy_connect"]:
        if not re.search(r"\b_" + name + r"$", exports, re.MULTILINE):
            raise RuntimeError("Required symbol is missing: " + name)
    for name, (size, digest) in prepare.DDI_FILES.items():
        prepare.download(prepare.DDI_BASE + name, output / "LocationDDI" / name, size, digest)
    write_notices(source, output, env)
    (output / "build-manifest.json").write_text(json.dumps({
        "source_revision": REVISION, "source_sha256": SOURCE_SHA256,
        "build_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "tls_verifier_sha256": hashlib.sha256(Path(__file__).with_name("idevice-sni.rs").read_bytes()).hexdigest(),
        "tls_tests_sha256": hashlib.sha256(Path(__file__).with_name("idevice-tls-tests.rs").read_bytes()).hexdigest(),
        "features": FEATURES, "rust_toolchain": TOOLCHAIN, "targets": TARGETS, "operation_timeout_seconds": 30,
        "image_mounter_timeout_seconds": 120,
        "release_lto": False, "embed_bitcode": False,
    }, indent=2))
    print("Built bounded idevice and verified DDI assets:", output)


if __name__ == "__main__":
    main()
