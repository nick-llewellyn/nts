//! Android-only hybrid TLS server-cert verifier.
//!
//! Wraps [`rustls_platform_verifier::Verifier`] so that the system trust
//! store (and any user / MDM-installed roots) remains the primary source
//! of truth for chain validation. When — and only when — the platform
//! reports [`CertificateError::Revoked`], this verifier retries the chain
//! against [`webpki_roots::TLS_SERVER_ROOTS`].
//!
//! # Why
//!
//! Android's [`PKIXRevocationChecker`] hard-fails any chain whose leaf
//! does not advertise an OCSP responder URL in the AIA extension and
//! does not arrive with a stapled OCSP response. Let's Encrypt's R12
//! intermediate (and the short-lived profile rotated under it)
//! deliberately omits the OCSP entry per
//! <https://letsencrypt.org/2024/12/05/ending-ocsp.html>, so every
//! NTS-KE handshake to a server using that chain (e.g. `nts.netnod.se`,
//! `ptbtime1.ptb.de`) fails with a misleading `Revoked` status. The
//! certs are not actually revoked: the platform simply cannot check.
//!
//! Falling back specifically on `Revoked` preserves the platform path
//! for every other failure category (`Expired`, `UnknownIssuer`,
//! `BadEncoding`, …) — those genuinely indicate a bad chain regardless
//! of OCSP — while letting Let's Encrypt-style chains succeed against
//! a static webpki-roots anchor set.
//!
//! # Defence-in-depth: native-verifier JNI failures
//!
//! `rustls-platform-verifier` 0.5.x maps every `JNIError` raised while
//! invoking the Kotlin `CertificateVerifier` glue to
//! `Error::General("failed to call native verifier: …")` (see
//! `rustls-platform-verifier-0.5.3/src/verification/android.rs`). The
//! most common cause in the wild is R8 / ProGuard dead-code-eliminating
//! the AAR's `org.rustls.platformverifier.*` classes when the host app
//! ships release builds without the keep rules documented in
//! `RustlsBootstrap.kt`. The Rust side cannot recover the AAR at
//! runtime, but it *can* avoid hard-failing every NTS-KE handshake by
//! retrying against `webpki-roots` — exactly the same safety net we
//! use for `Revoked`. We keep this fallback narrowly scoped to the
//! exact `Error::General` string surfaced by upstream so that other
//! `General` failures (e.g. `webpki` chain-building errors that bubble
//! up through the same variant) still propagate.
//!
//! [`PKIXRevocationChecker`]: https://developer.android.com/reference/java/security/cert/PKIXRevocationChecker

use std::sync::{Arc, OnceLock};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::client::WebPkiServerVerifier;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{
    CertificateError, DigitallySignedStruct, Error, PeerIncompatible, RootCertStore,
    SignatureScheme,
};

use rustls_platform_verifier::Verifier as PlatformVerifier;

/// Substring uniquely identifying the `Error::General` variant that
/// `rustls-platform-verifier` synthesises when a `JNIError` is raised
/// while invoking the Kotlin `CertificateVerifier` glue. Pinned to the
/// upstream format string so that breakage in the upstream wording
/// surfaces as a build-time test failure rather than a silent
/// behavioural regression.
const NATIVE_VERIFIER_JNI_MARKER: &str = "failed to call native verifier";

/// Platform-first verifier with a webpki-roots safety net for chains
/// whose only platform-side failure is a missing OCSP responder URL.
///
/// Construction is cheap: the platform [`Verifier`][PlatformVerifier]
/// resolves the `CryptoProvider` lazily on first use and the webpki-roots
/// trust anchor set is parsed lazily on first fallback (see
/// [`HybridVerifier::fallback`]). A fresh instance per `ClientConfig`
/// build is fine.
#[derive(Debug)]
pub struct HybridVerifier {
    platform: Arc<PlatformVerifier>,
    /// Lazily built; the parsing cost of the bundled trust-anchor set is
    /// paid once, only on the first `Revoked` we actually see in the wild.
    fallback: OnceLock<Arc<WebPkiServerVerifier>>,
}

impl HybridVerifier {
    pub fn new() -> Self {
        Self {
            platform: Arc::new(PlatformVerifier::new()),
            fallback: OnceLock::new(),
        }
    }

    fn fallback(&self) -> Result<&Arc<WebPkiServerVerifier>, Error> {
        if let Some(v) = self.fallback.get() {
            return Ok(v);
        }
        let mut roots = RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let verifier = WebPkiServerVerifier::builder(Arc::new(roots))
            .build()
            .map_err(|e| Error::General(format!("nts: webpki-roots fallback unavailable: {e}")))?;
        // First-writer-wins under a TLS-config build race; the loser drops
        // its own `verifier` and the next `get` returns the winner.
        let _ = self.fallback.set(verifier);
        Ok(self.fallback.get().expect("just populated"))
    }
}

impl Default for HybridVerifier {
    fn default() -> Self {
        Self::new()
    }
}

impl ServerCertVerifier for HybridVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        match self.platform.verify_server_cert(
            end_entity,
            intermediates,
            server_name,
            ocsp_response,
            now,
        ) {
            Ok(v) => Ok(v),
            Err(Error::InvalidCertificate(CertificateError::Revoked)) => {
                let host = host_for_log(server_name);
                log::warn!(
                    target: "nts::hybrid_verifier",
                    "platform verifier reported Revoked for {host}; retrying with webpki-roots (likely missing OCSP AIA, e.g. Let's Encrypt R12)",
                );
                let fallback = self.fallback()?;
                fallback.verify_server_cert(
                    end_entity,
                    intermediates,
                    server_name,
                    ocsp_response,
                    now,
                )
            }
            Err(Error::General(msg)) if msg.contains(NATIVE_VERIFIER_JNI_MARKER) => {
                let host = host_for_log(server_name);
                log::warn!(
                    target: "nts::hybrid_verifier",
                    "platform verifier failed via JNI for {host} ({msg}); retrying with webpki-roots (likely R8 stripped org.rustls.platformverifier.* — see RustlsBootstrap.kt for the required keep rules)",
                );
                let fallback = self.fallback()?;
                fallback.verify_server_cert(
                    end_entity,
                    intermediates,
                    server_name,
                    ocsp_response,
                    now,
                )
            }
            Err(other) => Err(other),
        }
    }

    /// RFC 8915 §3 forbids negotiating any TLS version below 1.3, so an
    /// NTS-KE handshake must never reach a TLS 1.2 signature-verification
    /// callback. The `rustls/tls12` Cargo feature is omitted in
    /// `rust/Cargo.toml` and `ke::TLS_PROTOCOL_VERSIONS`
    /// pins the negotiated version, so this method is unreachable in
    /// any well-formed build. We still implement it (the trait requires
    /// it) and fail closed via `PeerIncompatible::Tls12NotOfferedOrEnabled`
    /// to ensure that any future regression that re-enables TLS 1.2 in
    /// the dep graph cannot silently route an NTS-KE handshake through
    /// the platform verifier's TLS 1.2 path.
    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        Err(Error::PeerIncompatible(
            PeerIncompatible::Tls12NotOfferedOrEnabled,
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.platform.verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.platform.supported_verify_schemes()
    }
}

/// Render a [`ServerName`] as a `String` suitable for the warn-level
/// logs above. `DnsName` is the overwhelmingly common case for NTS-KE
/// (servers in `nts-sources.yml` are listed by hostname); IP literals
/// and any future variants fall through to `Debug`.
fn host_for_log(server_name: &ServerName<'_>) -> String {
    match server_name {
        ServerName::DnsName(d) => d.as_ref().to_owned(),
        other => format!("{other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::NATIVE_VERIFIER_JNI_MARKER;

    /// Pin the marker substring against the exact format string upstream
    /// emits in `rustls-platform-verifier-0.5.x`. If the upstream wording
    /// changes (e.g. on a major bump) this test fails loudly so the
    /// fallback can be re-pointed at the new variant rather than silently
    /// stop catching JNI failures.
    #[test]
    fn jni_marker_matches_upstream_format() {
        // Upstream synthesises:
        //   `Error::General(format!("failed to call native verifier: {e:?}"))`
        // (see rustls-platform-verifier-0.5.3/src/verification/android.rs).
        // We mirror the exact prefix; any `{e:?}` payload still satisfies
        // `contains`.
        let synthesised = format!("failed to call native verifier: {:?}", "Error");
        assert!(
            synthesised.contains(NATIVE_VERIFIER_JNI_MARKER),
            "upstream format string drifted; expected to contain `{NATIVE_VERIFIER_JNI_MARKER}`, got `{synthesised}`",
        );
    }
}
