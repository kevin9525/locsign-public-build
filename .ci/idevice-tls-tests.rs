// Public synthetic LocSign fixtures only. No real pairing records or device keys.
use super::*;
use base64::Engine;
use rustls::{
    CertificateError, ClientConnection, Error, ServerConfig, ServerConnection,
    SignatureAlgorithm, SignatureScheme, SupportedProtocolVersion,
    sign::{CertifiedKey, Signer, SigningKey, SingleCertAndKey},
};
use std::io::Cursor;

const DEVICE: &[u8] = include_bytes!("locsign_tls_fixtures/pairing-empty-device.der");
const OTHER_DEVICE: &[u8] = include_bytes!("locsign_tls_fixtures/pairing-empty-expired.der");
const DEVICE_KEY: &[u8] = include_bytes!("locsign_tls_fixtures/pairing-empty-device-key.der");
const ROOT: &[u8] = include_bytes!("locsign_tls_fixtures/pairing-empty-root.der");
const HOST: &[u8] = include_bytes!("locsign_tls_fixtures/pairing-host-cert.der");
const HOST_KEY: &[u8] = include_bytes!("locsign_tls_fixtures/pairing-host-key.der");

fn pairing() -> PairingFile {
    let pem = format!(
        "-----BEGIN RSA PRIVATE KEY-----\n{}\n-----END RSA PRIVATE KEY-----\n",
        base64::prelude::BASE64_STANDARD.encode(HOST_KEY),
    );
    PairingFile {
        device_certificate: CertificateDer::from(DEVICE.to_vec()),
        host_private_key: pem.into_bytes(),
        host_certificate: CertificateDer::from(HOST.to_vec()),
        root_private_key: Vec::new(),
        root_certificate: CertificateDer::from(ROOT.to_vec()),
        system_buid: "synthetic-system".into(),
        host_id: "synthetic-host".into(),
        escrow_bag: None,
        wifi_mac_address: String::new(),
        udid: None,
    }
}

#[derive(Debug)]
struct CorruptSigningKey(Arc<dyn SigningKey>);

impl SigningKey for CorruptSigningKey {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        self.0.choose_scheme(offered).map(|signer| {
            Box::new(CorruptSigner(signer)) as Box<dyn Signer>
        })
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        self.0.algorithm()
    }
}

#[derive(Debug)]
struct CorruptSigner(Box<dyn Signer>);

impl Signer for CorruptSigner {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, Error> {
        let mut signature = self.0.sign(message)?;
        signature[0] ^= 1;
        Ok(signature)
    }

    fn scheme(&self) -> SignatureScheme {
        self.0.scheme()
    }
}

// Run actual Rustls client/server handshakes entirely in memory. Only the server
// is restricted to a version, so the client is the exact production config.
// Errors returned here must come from the client's certificate/signature checks.
fn handshake(
    record: &PairingFile,
    version: &'static SupportedProtocolVersion,
    peer_certificate: &[u8],
    peer_key: &[u8],
    corrupt_signature: bool,
) -> Result<(), Error> {
    let client_config = create_client_config(record).expect("valid synthetic client identity");
    let provider = client_config.crypto_provider().clone();
    let key = provider.key_provider
        .load_private_key(PrivateKeyDer::try_from(peer_key.to_vec()).unwrap())
        .unwrap();
    let key: Arc<dyn SigningKey> = if corrupt_signature {
        Arc::new(CorruptSigningKey(key))
    } else {
        key
    };
    let identity = CertifiedKey::new(vec![CertificateDer::from(peer_certificate.to_vec())], key);
    let server_config = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[version]).unwrap()
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(SingleCertAndKey::from(identity)));
    let mut server = ServerConnection::new(Arc::new(server_config)).unwrap();
    // Pairing certificates have no DNS SAN; this arbitrary name must not affect
    // the exact authenticated device pin or handshake proof verification.
    let mut client = ClientConnection::new(
        Arc::new(client_config), ServerName::try_from("synthetic.invalid").unwrap(),
    ).unwrap();

    for _ in 0..16 {
        let mut to_server = Vec::new();
        client.write_tls(&mut to_server).unwrap();
        if !to_server.is_empty() {
            server.read_tls(&mut Cursor::new(to_server)).unwrap();
            server.process_new_packets().expect("server accepted client handshake");
        }
        let mut to_client = Vec::new();
        server.write_tls(&mut to_client).unwrap();
        if !to_client.is_empty() {
            client.read_tls(&mut Cursor::new(to_client)).unwrap();
            client.process_new_packets()?;
        }
        if !client.is_handshaking() && !server.is_handshaking() {
            assert_eq!(client.protocol_version(), Some(version.version));
            return Ok(());
        }
    }
    panic!("synthetic TLS handshake did not complete within 16 flights");
}

#[test]
fn tls12_accepts_exact_verified_sha1_empty_subject_leaf() {
    handshake(&pairing(), &rustls::version::TLS12, DEVICE, DEVICE_KEY, false).unwrap();
}

#[test]
fn tls13_accepts_exact_verified_sha1_empty_subject_leaf() {
    handshake(&pairing(), &rustls::version::TLS13, DEVICE, DEVICE_KEY, false).unwrap();
}

fn rejects_other_certificate(version: &'static SupportedProtocolVersion) {
    // Same public key, different DER. A key-only pin would wrongly accept it.
    assert!(matches!(
        handshake(&pairing(), version, OTHER_DEVICE, DEVICE_KEY, false),
        Err(Error::InvalidCertificate(CertificateError::ApplicationVerificationFailure)),
    ));
}

#[test]
fn tls12_rejects_other_leaf_with_same_public_key() {
    rejects_other_certificate(&rustls::version::TLS12);
}

#[test]
fn tls13_rejects_other_leaf_with_same_public_key() {
    rejects_other_certificate(&rustls::version::TLS13);
}

fn rejects_root_substitute(version: &'static SupportedProtocolVersion) {
    let mut record = pairing();
    record.root_certificate = CertificateDer::from(HOST.to_vec());
    assert!(matches!(
        handshake(&record, version, HOST, HOST_KEY, false),
        Err(Error::InvalidCertificate(CertificateError::ApplicationVerificationFailure)),
    ));
}

#[test]
fn tls12_rejects_root_certificate_as_device_leaf() {
    rejects_root_substitute(&rustls::version::TLS12);
}

#[test]
fn tls13_rejects_root_certificate_as_device_leaf() {
    rejects_root_substitute(&rustls::version::TLS13);
}

fn rejects_invalid_signature(version: &'static SupportedProtocolVersion) {
    assert!(matches!(
        handshake(&pairing(), version, DEVICE, DEVICE_KEY, true),
        Err(Error::InvalidCertificate(CertificateError::BadSignature)),
    ));
}

#[test]
fn tls12_rejects_invalid_handshake_signature_for_pinned_leaf() {
    rejects_invalid_signature(&rustls::version::TLS12);
}

#[test]
fn tls13_rejects_invalid_handshake_signature_for_pinned_leaf() {
    rejects_invalid_signature(&rustls::version::TLS13);
}

#[test]
fn missing_device_pin_is_rejected_before_connecting() {
    let mut record = pairing();
    record.device_certificate = CertificateDer::from(Vec::new());
    assert!(create_client_config(&record).is_err());
}

#[test]
fn mismatched_host_identity_returns_error_instead_of_panicking() {
    let mut record = pairing();
    record.host_certificate = CertificateDer::from(DEVICE.to_vec());
    assert!(create_client_config(&record).is_err());
}
