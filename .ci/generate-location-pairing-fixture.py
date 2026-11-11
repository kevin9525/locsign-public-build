"""Generate a public synthetic device leaf under the existing synthetic host CA."""
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

fixtures = Path(__file__).resolve().parents[1] / "Tests/LocSignTests/Fixtures"
root = x509.load_der_x509_certificate((fixtures / "pairing-host-cert.der").read_bytes())
root_key = serialization.load_der_private_key((fixtures / "pairing-host-key.der").read_bytes(), password=None)
device_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
certificate = (x509.CertificateBuilder()
    .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "LocSign synthetic location device")]))
    .issuer_name(root.subject)
    .public_key(device_key.public_key())
    .serial_number(421)
    .not_valid_before(root.not_valid_before_utc)
    .not_valid_after(root.not_valid_after_utc)
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
        key_encipherment=True, data_encipherment=False, key_agreement=False,
        key_cert_sign=False, crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
    .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()), critical=False)
    .sign(root_key, hashes.SHA256()))
(fixtures / "pairing-location-device.der").write_bytes(certificate.public_bytes(serialization.Encoding.DER))
print("Generated synthetic device certificate; device private key is not retained.")
