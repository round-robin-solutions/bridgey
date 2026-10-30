//! The QUIC tunnel (spec 5.3, 7.4): TLS 1.3 with self-signed Ed25519 certificates in both
//! directions, optional pins from signalling, ALPN `bridgey/1`, and the exporter that binds the
//! inner Bridgey handshake to this connection.

use bridgey_connect_proto::{b64, derive};
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, DistinguishedName, SignatureScheme};
use std::sync::Arc;
use std::time::Duration;

pub const ALPN: &[u8] = b"bridgey/1";
pub const EXPORTER_LABEL: &[u8] = b"EXPORTER-bridgey-tunnel-v1";

pub struct Identity {
    pub cert: CertificateDer<'static>,
    key: PrivatePkcs8KeyDer<'static>,
    /// `certSha256`, base64url.
    pub cert_sha256: String,
}

impl Identity {
    /// A fresh Ed25519 key and self-signed certificate (made at start, renewed every 24 hours).
    pub fn generate() -> Identity {
        let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ED25519).expect("ed25519 key");
        let params = rcgen::CertificateParams::new(vec!["bridgey".to_string()]).expect("params");
        let cert = params.self_signed(&key).expect("self-signed certificate");
        let der = cert.der().clone();
        Identity { cert_sha256: b64::url_encode(&derive::sha256(&der)), cert: der, key: PrivatePkcs8KeyDer::from(key.serialize_der()) }
    }

    fn key(&self) -> PrivateKeyDer<'static> {
        PrivateKeyDer::Pkcs8(self.key.clone_key())
    }
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

pub fn cert_hash(cert: &CertificateDer<'_>) -> String {
    b64::url_encode(&derive::sha256(cert))
}

/// Accepts the peer's certificate when it matches `pin` (if any) and proves possession of its key.
/// The Web PKI is never used between devices; identity comes from the channel-bound signatures.
#[derive(Debug)]
struct Pinned {
    pin: Option<String>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(&self, end_entity: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: &ServerName<'_>, _: &[u8], _: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
        match &self.pin {
            Some(pin) if *pin != cert_hash(end_entity) => Err(rustls::Error::General("certificate pin mismatch".into())),
            _ => Ok(ServerCertVerified::assertion()),
        }
    }

    fn verify_tls12_signature(&self, _: &[u8], _: &CertificateDer<'_>, _: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2 is not used".into()))
    }

    fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// Requires a client certificate and checks possession; pins are checked after the handshake.
#[derive(Debug)]
struct AnyClient {
    provider: Arc<CryptoProvider>,
}

impl ClientCertVerifier for AnyClient {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(&self, _: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: UnixTime) -> Result<ClientCertVerified, rustls::Error> {
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(&self, _: &[u8], _: &CertificateDer<'_>, _: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2 is not used".into()))
    }

    fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// Spec 7.4 values; keep-alive 15 s on NATed paths and 25 s on LAN and VPN.
pub fn transport(keep_alive: Duration) -> Arc<quinn::TransportConfig> {
    let mut t = quinn::TransportConfig::default();
    t.keep_alive_interval(Some(keep_alive));
    t.max_idle_timeout(Some(quinn::IdleTimeout::try_from(Duration::from_secs(45)).expect("idle")));
    t.stream_receive_window(quinn::VarInt::from_u32(4 << 20));
    t.receive_window(quinn::VarInt::from_u32(16 << 20));
    t.send_window(16 << 20);
    t.max_concurrent_uni_streams(quinn::VarInt::from_u32(16));
    t.max_concurrent_bidi_streams(quinn::VarInt::from_u32(4));
    // Relay paths carry at most 1,280-byte UDP payloads; path MTU discovery stays off in phase 1.
    t.initial_mtu(1_200);
    t.mtu_discovery_config(None);
    Arc::new(t)
}

pub fn server_config(identity: &Identity) -> quinn::ServerConfig {
    let provider = provider();
    let mut tls = rustls::ServerConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .expect("TLS 1.3")
        .with_client_cert_verifier(Arc::new(AnyClient { provider }))
        .with_single_cert(vec![identity.cert.clone()], identity.key())
        .expect("server certificate");
    tls.alpn_protocols = vec![ALPN.to_vec()];
    tls.max_early_data_size = 0;
    let mut config = quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls).expect("QUIC server")));
    config.transport_config(transport(Duration::from_secs(15)));
    config.migration(true);
    config
}

pub fn client_config(identity: &Identity, pin: Option<String>, keep_alive: Duration) -> quinn::ClientConfig {
    let provider = provider();
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .expect("TLS 1.3")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Pinned { pin, provider }))
        .with_client_auth_cert(vec![identity.cert.clone()], identity.key())
        .expect("client certificate");
    tls.alpn_protocols = vec![ALPN.to_vec()];
    tls.enable_early_data = false;
    let mut config = quinn::ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls).expect("QUIC client")));
    config.transport_config(transport(keep_alive));
    config
}

/// RFC 9443: endpoints sharing a socket with STUN and TURN must not grease the QUIC bit.
pub fn endpoint_config() -> quinn::EndpointConfig {
    let mut config = quinn::EndpointConfig::default();
    config.grease_quic_bit(false);
    config
}

/// `TLS-Exporter("EXPORTER-bridgey-tunnel-v1", "", 32)`, base64 (standard, as the apps encode keys).
pub fn exporter(connection: &quinn::Connection) -> Option<String> {
    let mut out = [0u8; 32];
    connection.export_keying_material(&mut out, EXPORTER_LABEL, b"").ok()?;
    Some(b64::std_encode(&out))
}

/// The peer's certificate hash, for checking a pin after the handshake.
pub fn peer_cert_hash(connection: &quinn::Connection) -> Option<String> {
    let identity = connection.peer_identity()?;
    let certs = identity.downcast::<Vec<CertificateDer<'static>>>().ok()?;
    certs.first().map(cert_hash)
}
