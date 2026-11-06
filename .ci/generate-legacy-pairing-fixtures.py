"""Public synthetic Apple pairing fixtures without an authority key identifier."""
from pathlib import Path
import subprocess
import tempfile

fixtures = Path(__file__).resolve().parents[1] / "Tests/LocSignTests/Fixtures"

def run(*args):
    result = subprocess.run(["openssl", *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)

with tempfile.TemporaryDirectory(prefix="locsign-synthetic-legacy-") as folder:
    work = Path(folder)
    root_key, device_key = work / "root-key.pem", work / "device-key.pem"
    for key in (root_key, device_key):
        run("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", key)
    root, request = work / "root.pem", work / "device.csr"
    run("req", "-new", "-x509", "-key", root_key, "-out", root, "-subj", "/",
        "-days", "3650", "-sha1", "-set_serial", "0", "-addext", "authorityKeyIdentifier=none",
        "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "subjectKeyIdentifier=hash")
    run("req", "-new", "-key", device_key, "-out", request, "-subj", "/")
    (work / "index.txt").write_text("", encoding="ascii")
    (work / "serial").write_text("01\n", encoding="ascii")
    config = work / "ca.cnf"
    config.write_text(f"""[ca]
default_ca=local
[local]
database={work.as_posix()}/index.txt
serial={work.as_posix()}/serial
new_certs_dir={work.as_posix()}
certificate={root.as_posix()}
private_key={root_key.as_posix()}
default_md=sha1
policy=optional
unique_subject=no
[optional]
commonName=optional
""", encoding="ascii")
    for name, ca, extra, dates in [
        ("device", False, "", None),
        ("expired", False, "", ("20200101000000Z", "20210101000000Z")),
        ("future", False, "", ("20400101000000Z", "20500101000000Z")),
        ("critical", False, "1.2.3.4=critical,DER:05:00\n", None),
        ("ca-leaf", True, "", None),
    ]:
        extensions = work / "extensions.cnf"
        extensions.write_text("authorityKeyIdentifier=none\nsubjectKeyIdentifier=hash\n"
                              f"basicConstraints=critical,CA:{str(ca).upper()}\n"
                              "keyUsage=critical,digitalSignature,keyEncipherment\n" + extra, encoding="ascii")
        cert = work / (name + ".pem")
        if dates:
            run("ca", "-batch", "-notext", "-config", config, "-in", request,
                "-startdate", dates[0], "-enddate", dates[1], "-extfile", extensions, "-out", cert)
        else:
            run("x509", "-req", "-in", request, "-CA", root, "-CAkey", root_key,
                "-set_serial", "0", "-days", "3650", "-sha1", "-extfile", extensions, "-out", cert)
        run("x509", "-in", cert, "-outform", "DER", "-out", fixtures / ("pairing-legacy-" + name + ".der"))
    run("x509", "-in", root, "-outform", "DER", "-out", fixtures / "pairing-legacy-root.der")
    run("pkey", "-in", device_key, "-outform", "DER", "-out", fixtures / "pairing-legacy-key.der")
    damaged = bytearray((fixtures / "pairing-legacy-device.der").read_bytes())
    damaged[-1] ^= 1
    (fixtures / "pairing-legacy-bad-signature.der").write_bytes(damaged)
    # An expired root with the same public key must still be rejected.
    root_request = work / "root.csr"
    run("req", "-new", "-key", root_key, "-out", root_request, "-subj", "/")
    ext = work / "root-ext.cnf"
    ext.write_text("authorityKeyIdentifier=none\nsubjectKeyIdentifier=hash\nbasicConstraints=critical,CA:TRUE\n", encoding="ascii")
    expired = work / "expired-root.pem"
    run("ca", "-selfsign", "-batch", "-notext", "-config", config, "-in", root_request,
        "-startdate", "20200101000000Z", "-enddate", "20210101000000Z", "-extfile", ext, "-out", expired)
    run("x509", "-in", expired, "-outform", "DER", "-out", fixtures / "pairing-legacy-expired-root.der")
print("Generated synthetic legacy fixtures. No real device data used.")
