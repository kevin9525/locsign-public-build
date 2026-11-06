"""Generate public synthetic Apple-format pairing TLS fixtures with OpenSSL."""
from pathlib import Path
import subprocess
import tempfile


def run(*args: str) -> None:
    result = subprocess.run(["openssl", *args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)


fixtures = Path(__file__).resolve().parents[1] / "Tests" / "LocSignTests" / "Fixtures"
with tempfile.TemporaryDirectory(prefix="locsign-synthetic-pairing-") as folder:
    work = Path(folder)
    root_key = str(work / "root-key.pem")
    root = str(work / "root.pem")
    device_key = str(work / "device-key.pem")
    request = str(work / "device.csr")
    device = str(work / "device.pem")
    extensions = work / "extensions.cnf"
    extensions.write_text("basicConstraints=critical,CA:FALSE\n"
                          "subjectKeyIdentifier=hash\n"
                          "keyUsage=critical,digitalSignature,keyEncipherment\n", encoding="ascii")
    run("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", root_key)
    run("req", "-new", "-x509", "-key", root_key, "-out", root, "-subj", "/",
        "-days", "3650", "-sha1", "-set_serial", "0",
        "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "subjectKeyIdentifier=hash")
    run("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", device_key)
    run("req", "-new", "-key", device_key, "-out", request, "-subj", "/")
    run("x509", "-req", "-in", request, "-CA", root, "-CAkey", root_key,
        "-set_serial", "0", "-days", "3650", "-sha1", "-extfile", str(extensions), "-out", device)
    for source, name in [(root, "pairing-empty-root.der"), (device, "pairing-empty-device.der")]:
        run("x509", "-in", source, "-outform", "DER", "-out", str(fixtures / name))
    run("pkey", "-in", device_key, "-outform", "DER", "-out", str(fixtures / "pairing-empty-device-key.der"))

    # The expired certificate is validly signed but ended in 2021.
    (work / "index.txt").write_text("", encoding="ascii")
    (work / "serial").write_text("01\n", encoding="ascii")
    config = work / "ca.cnf"
    config.write_text(f"""[ca]
default_ca=pairing_ca
[pairing_ca]
database={work.as_posix()}/index.txt
serial={work.as_posix()}/serial
new_certs_dir={work.as_posix()}
certificate={Path(root).as_posix()}
private_key={Path(root_key).as_posix()}
default_md=sha1
policy=optional_subject
unique_subject=no
x509_extensions=leaf
[optional_subject]
commonName=optional
[leaf]
basicConstraints=critical,CA:FALSE
subjectKeyIdentifier=hash
keyUsage=critical,digitalSignature,keyEncipherment
""", encoding="ascii")
    expired = str(work / "expired.pem")
    run("ca", "-batch", "-notext", "-config", str(config), "-in", request,
        "-startdate", "20200101000000Z", "-enddate", "20210101000000Z", "-out", expired)
    run("x509", "-in", expired, "-outform", "DER", "-out", str(fixtures / "pairing-empty-expired.der"))

    # Change only the signature, leaving the public key and DER structure intact.
    tampered = bytearray((fixtures / "pairing-empty-device.der").read_bytes())
    tampered[-1] ^= 1
    (fixtures / "pairing-empty-bad-signature.der").write_bytes(tampered)

print("Generated five synthetic pairing TLS fixtures; temporary CA private key removed.")
