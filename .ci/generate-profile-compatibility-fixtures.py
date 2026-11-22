"""Supplement public synthetic fixtures using their existing public test key.

No Apple-issued profile, certificate, identity, or device data is used.
"""
from pathlib import Path
import plistlib
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.serialization import pkcs7

root = Path(__file__).resolve().parents[1] / 'Tests/LocSignTests/Fixtures'
source = (root / 'profile-valid.mobileprovision').read_bytes()
start = source.index(b'<?xml')
payload = plistlib.loads(source[start:source.index(b'</plist>', start) + 8])
chain = pkcs7.load_der_pkcs7_certificates(source)
signer = next(c for c in chain if c.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
              == 'Apple iPhone OS Provisioning Profile Signing')
key = serialization.load_pem_private_key((root / 'test-key.pem').read_bytes(), None)
assert signer.public_key().public_numbers() == key.public_key().public_numbers()
extras = {'com.apple.security.application-groups': ['group.com.synthetic.test'],
          'com.apple.developer.kernel.increased-memory-limit': True}
variants = {
    'optional-authorizations': extras,
    'empty-app-groups': dict(extras, **{'com.apple.security.application-groups': []}),
    'malformed-app-groups': dict(extras, **{'com.apple.security.application-groups': 'group.com.synthetic.test'}),
    'wildcard-app-groups': dict(extras, **{'com.apple.security.application-groups': ['group.*']}),
    'malformed-memory-limit': dict(extras, **{'com.apple.developer.kernel.increased-memory-limit': 'true'}),
    'optional-with-unknown': dict(extras, **{'aps-environment': 'development'}),
    'optional-with-foreign-keychain': dict(extras, **{'keychain-access-groups': ['OTHERPREFIX.*']}),
}
for label, values in variants.items():
    data = plistlib.dumps(dict(payload, Entitlements=dict(payload['Entitlements'], **values)))
    builder = pkcs7.PKCS7SignatureBuilder().set_data(data).add_signer(signer, key, hashes.SHA256())
    for cert in chain:
        if cert != signer:
            builder = builder.add_certificate(cert)
    (root / ('profile-' + label + '.mobileprovision')).write_bytes(
        builder.sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary]))
print('Generated seven supplemental synthetic profile fixtures.')


def write_extension_profile():
    """App extension profile: its own App ID inside the parent's namespace."""
    app_id = 'PREFIX1234.com.test.app.widget'
    entitlements = dict(payload['Entitlements'], **{'application-identifier': app_id,
                                                    'keychain-access-groups': [app_id]})
    data = plistlib.dumps(dict(payload, Entitlements=entitlements, AppIDName='Synthetic Widget',
                               Name='Synthetic Widget Profile', UUID='5E0B3C1A-7D21-4C8E-9F3B-2A6D4E8F1C07'))
    builder = pkcs7.PKCS7SignatureBuilder().set_data(data).add_signer(signer, key, hashes.SHA256())
    for cert in chain:
        if cert != signer:
            builder = builder.add_certificate(cert)
    (root / 'profile-extension.mobileprovision').write_bytes(
        builder.sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary]))


write_extension_profile()
print('Generated the synthetic extension profile fixture.')
