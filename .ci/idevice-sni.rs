// LocSign's pairing TLS verifier for pinned idevice v0.1.68.
// DeviceCertificate is the exact leaf authenticated by the app's existing
// pairing-root trust validation and completed SecureTransport handshake.
// iOS pairing certificates may have empty names and SHA1 issuer signatures;
// hostname/WebPKI chain validation is not the trust model for this connection.
use rustls::{
    ClientConfig, DigitallySignedStruct,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{WebPkiSupportedAlgorithms, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime, pem::PemObject},
    server::ParsedCertificate,
};
use std::sync::Arc;

use crate::{IdeviceError, pairing_file::PairingFile};

#[derive(Debug)]
struct PinnedDeviceVerifier {
    device_certificate: CertificateDer<'static>,
    algorithms: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for PinnedDeviceVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if end_entity.as_ref() != self.device_certificate.as_ref() {
            return Err(rustls::Error::InvalidCertificate(
                rustls::CertificateError::ApplicationVerificationFailure,
            ));
        }
        // The pin was authenticated before entering native code. Matching the
        // entire DER prevents a different certificate with the same public key
        // or pairing root from being substituted. The callbacks below still
        // require the peer to prove possession of this leaf's private key.
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

pub fn create_client_config(pairing_file: &PairingFile) -> Result<ClientConfig, IdeviceError> {
    // An absent/malformed leaf is an error, never a request to disable checks.
    ParsedCertificate::try_from(&pairing_file.device_certificate)?;
    let private_key = PrivateKeyDer::from_pem_slice(&pairing_file.host_private_key)?;
    let builder = ClientConfig::builder();
    let verifier = PinnedDeviceVerifier {
        device_certificate: pairing_file.device_certificate.clone(),
        algorithms: builder.crypto_provider().signature_verification_algorithms,
    };
    Ok(builder
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_client_auth_cert(vec![pairing_file.host_certificate.clone()], private_key)?)
}

#[cfg(test)]
#[path = "locsign_tls_tests.rs"]
mod locsign_tls_tests;
