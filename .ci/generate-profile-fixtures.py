"""Generate deliberately public synthetic profile-signing fixtures; no Apple data."""
from pathlib import Path
from datetime import datetime, timezone
import plistlib
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs7

root = Path(__file__).resolve().parents[1] / 'Tests/LocSignTests/Fixtures'
key = serialization.load_pem_private_key((root/'test-key.pem').read_bytes(), None)
start, end = datetime(2020,1,1,tzinfo=timezone.utc), datetime(2100,1,1,tzinfo=timezone.utc)
def name(cn): return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
def cert(cn, public_key, issuer_name, issuer_key, serial, ca=False, before=start, after=end):
    return (x509.CertificateBuilder().subject_name(name(cn)).issuer_name(issuer_name)
        .public_key(public_key).serial_number(serial).not_valid_before(before).not_valid_after(after)
        .add_extension(x509.BasicConstraints(ca=ca,path_length=1 if ca else None),True)
        .add_extension(x509.KeyUsage(digital_signature=True,content_commitment=False,key_encipherment=False,
            data_encipherment=False,key_agreement=False,key_cert_sign=ca,crl_sign=ca,
            encipher_only=False,decipher_only=False),True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(public_key),False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()),False)
        .sign(issuer_key,hashes.SHA256()))
root_key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
root_cert=cert('LocSign Synthetic Profile Root',root_key.public_key(),name('LocSign Synthetic Profile Root'),root_key,100,True)
ca_key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
ca=cert('Apple iPhone Certification Authority',ca_key.public_key(),root_cert.subject,root_key,101,True)
signer=cert('Apple iPhone OS Provisioning Profile Signing',key.public_key(),ca.subject,ca_key,102)
wrong_signer=cert('Unrelated Apple Service',key.public_key(),ca.subject,ca_key,103)
expired_signer=cert('Apple iPhone OS Provisioning Profile Signing',key.public_key(),ca.subject,ca_key,104,after=datetime(2021,1,1,tzinfo=timezone.utc))
dev=cert('LocSign Synthetic Development',key.public_key(),ca.subject,ca_key,105)
expired_dev=cert('LocSign Synthetic Development',key.public_key(),ca.subject,ca_key,106,after=datetime(2021,1,1,tzinfo=timezone.utc))
second_key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
second=cert('Apple iPhone OS Provisioning Profile Signing',second_key.public_key(),ca.subject,ca_key,107)
(root/'profile-root.cer').write_bytes(root_cert.public_bytes(serialization.Encoding.DER))
(root/'profile-dev.cer').write_bytes(dev.public_bytes(serialization.Encoding.DER))
(root/'profile-expired-dev.cer').write_bytes(expired_dev.public_bytes(serialization.Encoding.DER))
(root/'profile-other-key.pem').write_bytes(second_key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
base={
 'UUID':'00000000-1111-2222-3333-444444444444','Name':'Synthetic profile','TeamIdentifier':['TEAM12345'],
 'ApplicationIdentifierPrefix':['PREFIX1234'], 'CreationDate':datetime(2020,1,1), 'ExpirationDate':datetime(2099,1,1),
 'ProvisionedDevices':['SYNTHETIC-UDID'], 'DeveloperCertificates':[dev.public_bytes(serialization.Encoding.DER)],
 'Entitlements':{'application-identifier':'PREFIX1234.com.test.app','com.apple.developer.team-identifier':'TEAM12345',
                 'get-task-allow':True,'keychain-access-groups':['PREFIX1234.com.test.app']}}
def cms(payload, leaf=signer, extra_signer=False):
    b=pkcs7.PKCS7SignatureBuilder().set_data(payload).add_signer(leaf,key,hashes.SHA256()).add_certificate(ca)
    if extra_signer: b=b.add_signer(second,second_key,hashes.SHA256())
    return b.sign(serialization.Encoding.DER,[pkcs7.PKCS7Options.Binary])
def write(label,payload,**kw): (root/('profile-'+label+'.mobileprovision')).write_bytes(cms(plistlib.dumps(payload),**kw))
write('valid',base)
write('wrong-signer',base,leaf=wrong_signer)
write('expired-signer',base,leaf=expired_signer)
write('two-signers',base,extra_signer=True)
write('expired',dict(base,ExpirationDate=datetime(2021,1,1)))
write('expired-certificate',dict(base,DeveloperCertificates=[expired_dev.public_bytes(serialization.Encoding.DER)]))
write('wrong-prefix',dict(base,ApplicationIdentifierPrefix=['WRONGPREFIX']))
write('wildcard',dict(base,Entitlements=dict(base['Entitlements'],**{'application-identifier':'PREFIX1234.com.test.*'})))
write('unsupported-entitlement',dict(base,Entitlements=dict(base['Entitlements'],**{'aps-environment':'development'})))
write('keychain-allowlist',dict(base,Entitlements=dict(base['Entitlements'],**{'keychain-access-groups':['PREFIX1234.*','com.apple.token']})))
write('foreign-keychain',dict(base,Entitlements=dict(base['Entitlements'],**{'keychain-access-groups':['OTHERPREFIX.*']})))
raw=(root/'profile-valid.mobileprovision').read_bytes()
assert raw.count(b'SYNTHETIC-UDID')==1
(root/'profile-tampered.mobileprovision').write_bytes(raw.replace(b'SYNTHETIC-UDID',b'UNTRUSTED-UDI'))
(root/'profile-unsigned.plist').write_bytes(plistlib.dumps(base))
print('Generated synthetic profile fixtures; generated CA/signer private keys were not retained.')
