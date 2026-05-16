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
//! # `TrustMode` gating (3.1.0)
//!
//! Both per-chain fallback arms are gated by the [`KeTrustMode`]
//! plumbed in at `HybridVerifier::new(trust_mode)`. In
//! [`KeTrustMode::PlatformWithFallback`] (the historic default) the
//! safety net fires exactly as it did pre-3.1.0. In
//! [`KeTrustMode::PlatformOnly`] both arms are suppressed and the
//! platform verifier's error propagates verbatim — the `webpki-roots`
//! anchor set is never consulted. This makes `PlatformOnly` honour
//! its "no static-bundle downgrade" intent at the per-chain level on
//! Android, not just at the build-time `build_with_native_verifier`
//! decision fixed in 3.0.0.
//!
//! # Defence-in-depth: native-verifier JNI failures
//!
//! `rustls-platform-verifier` 0.5.x maps every `JNIError` raised while
//! invoking the Kotlin `CertificateVerifier` glue to
//! `Error::General("failed to call native verifier: …")` (see
//! `rustls-platform-verifier-0.5.3/src/verification/android.rs`). The
//! most common cause in the wild is R8 / ProGuard dead-code-eliminating
//! the AAR's `org.rustls.platformverifier.*` classes when the host app
//! ships release builds without the keep rules contributed by the
//! `nts` plugin's `android/consumer-rules.pro`. The Rust side cannot
//! recover the AAR at
//! runtime, but it *can* avoid hard-failing every NTS-KE handshake by
//! retrying against `webpki-roots` — exactly the same safety net we
//! use for `Revoked`. We keep this fallback narrowly scoped to the
//! exact `Error::General` string surfaced by upstream so that other
//! `General` failures (e.g. `webpki` chain-building errors that bubble
//! up through the same variant) still propagate.
//!
//! [`PKIXRevocationChecker`]: https://developer.android.com/reference/java/security/cert/PKIXRevocationChecker

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::client::WebPkiServerVerifier;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{
    CertificateError, DigitallySignedStruct, Error, PeerIncompatible, RootCertStore,
    SignatureScheme,
};

use rustls_platform_verifier::Verifier as PlatformVerifier;

use crate::nts::ke::KeTrustMode;
use crate::nts::trust_state::TRUST_STATE;

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
///
/// The per-chain fallback arms are gated by [`KeTrustMode`] passed at
/// construction time. [`KeTrustMode::PlatformWithFallback`] preserves
/// the historical safety-net behaviour; [`KeTrustMode::PlatformOnly`]
/// suppresses both fallback arms and propagates the platform verifier's
/// error verbatim. This makes `PlatformOnly` honour its
/// "no `webpki-roots` downgrade" intent at the per-chain level, not
/// just the build-time level fixed in 3.0.0.
#[derive(Debug)]
pub struct HybridVerifier {
    platform: Arc<dyn ServerCertVerifier>,
    /// Lazily built; the parsing cost of the bundled trust-anchor set is
    /// paid once, only on the first `Revoked` we actually see in the wild.
    /// Typed as `dyn ServerCertVerifier` so unit tests can pre-populate
    /// the `OnceLock` with a fake fallback via
    /// [`Self::with_platform_and_fallback`] without standing up a real
    /// `webpki-roots`-backed chain.
    fallback: OnceLock<Arc<dyn ServerCertVerifier>>,
    /// Per-instance count of `verify_server_cert` calls in which the
    /// `webpki-roots` fallback overrode a platform verdict. Read by
    /// `crate::nts::ke::perform_handshake` after the TLS handshake
    /// completes so the per-handshake `KeOutcome::trust_backend` can
    /// distinguish `Platform` from `PlatformWithHybridFallback` even
    /// though both run through the same `ServerCertVerifier`. The
    /// process-global counter in [`TRUST_STATE`] is bumped in
    /// lockstep so [`crate::api::nts::nts_trust_status`] sees the
    /// same fallback as a deployment-wide signal.
    fallback_count: AtomicU64,
    /// Trust-anchor policy for this verifier instance. Gates both
    /// per-chain fallback arms in [`Self::verify_server_cert`].
    trust_mode: KeTrustMode,
}

impl HybridVerifier {
    #[must_use]
    pub fn new(trust_mode: KeTrustMode) -> Self {
        Self {
            platform: Arc::new(PlatformVerifier::new()),
            fallback: OnceLock::new(),
            fallback_count: AtomicU64::new(0),
            trust_mode,
        }
    }

    /// Test-only constructor that injects a fake [`ServerCertVerifier`]
    /// in place of the real platform verifier. Lets unit tests pin the
    /// `trust_mode` gating on synthesised platform errors without
    /// standing up a real platform-verifier dependency or an Android
    /// runtime.
    #[cfg(test)]
    pub(crate) fn with_platform(
        trust_mode: KeTrustMode,
        platform: Arc<dyn ServerCertVerifier>,
    ) -> Self {
        Self {
            platform,
            fallback: OnceLock::new(),
            fallback_count: AtomicU64::new(0),
            trust_mode,
        }
    }

    /// Test-only constructor that injects both a fake platform
    /// verifier *and* a pre-populated fake fallback. Lets unit tests
    /// exercise the successful-fallback success path — the `Ok` arm
    /// of the `if result.is_ok()` block in each of the two curated
    /// fallback paths of [`Self::verify_server_cert`] — without
    /// having to construct a chain that actually validates against
    /// the bundled `webpki-roots`. The fallback is `.set()` into the
    /// `OnceLock` at construction so `verify_server_cert` reaches it
    /// without triggering the lazy webpki-roots build path.
    #[cfg(test)]
    pub(crate) fn with_platform_and_fallback(
        trust_mode: KeTrustMode,
        platform: Arc<dyn ServerCertVerifier>,
        fallback: Arc<dyn ServerCertVerifier>,
    ) -> Self {
        let fallback_lock = OnceLock::new();
        // The lock is freshly constructed and uniquely owned within
        // this function, so `set` cannot fail. Use `.expect()` rather
        // than `let _ =` so a future refactor that reorders the
        // construction (e.g. populating the lock elsewhere before
        // this point) fails loudly at the construction site rather
        // than silently no-opping the `set` and leaving the verifier
        // exercising the lazy `webpki-roots` build path the test seam
        // was meant to bypass. NB: the *production* lazy-init in
        // `Self::fallback()` deliberately uses `let _ = ... .set(...)`
        // because the race-loser there must silently drop its own
        // verifier — that pattern is correct in context and must not
        // be changed in lockstep with this site.
        fallback_lock
            .set(fallback)
            .expect("fresh OnceLock cannot already be set");
        Self {
            platform,
            fallback: fallback_lock,
            fallback_count: AtomicU64::new(0),
            trust_mode,
        }
    }

    /// Snapshot the per-instance fallback counter. `perform_handshake`
    /// samples this before-and-after to detect a hybrid-fallback
    /// firing on this specific handshake.
    pub fn fallback_count(&self) -> u64 {
        self.fallback_count.load(Ordering::Relaxed)
    }

    fn record_fallback(&self) {
        self.fallback_count.fetch_add(1, Ordering::Relaxed);
        TRUST_STATE.bump_hybrid_fallback();
    }

    fn fallback(&self) -> Result<&Arc<dyn ServerCertVerifier>, Error> {
        if let Some(v) = self.fallback.get() {
            return Ok(v);
        }
        let mut roots = RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        // The builder returns `Arc<WebPkiServerVerifier>`; the explicit
        // annotation coerces it to `Arc<dyn ServerCertVerifier>` at the
        // assignment site so the `OnceLock::set` call below has nothing
        // to infer.
        let verifier: Arc<dyn ServerCertVerifier> = WebPkiServerVerifier::builder(Arc::new(roots))
            .build()
            .map_err(|e| Error::General(format!("nts: webpki-roots fallback unavailable: {e}")))?;
        // First-writer-wins under a TLS-config build race; the loser drops
        // its own `verifier` and the next `get` returns the winner.
        let _ = self.fallback.set(verifier);
        Ok(self.fallback.get().expect("just populated"))
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
        let platform_result = self.platform.verify_server_cert(
            end_entity,
            intermediates,
            server_name,
            ocsp_response,
            now,
        );
        match platform_result {
            Ok(v) => Ok(v),
            Err(Error::InvalidCertificate(CertificateError::Revoked))
                if self.trust_mode == KeTrustMode::PlatformWithFallback =>
            {
                let fallback = self.fallback()?;
                let result = fallback.verify_server_cert(
                    end_entity,
                    intermediates,
                    server_name,
                    ocsp_response,
                    now,
                );
                // Both the warn line and the counter bump are gated on
                // `result.is_ok()` so they measure "fallback overrode a
                // platform verdict", not "fallback was attempted". A
                // failed fallback surfaces as the underlying webpki
                // error verbatim — no `WARN nts::hybrid_verifier` line
                // and no counter bump — so the invariant
                // `(grep -c WARN nts::hybrid_verifier) ==
                // nts_trust_status().android_hybrid_fallback_count`
                // holds across a process lifetime.
                if result.is_ok() {
                    let host = host_for_log(server_name);
                    log::warn!(
                        target: "nts::hybrid_verifier",
                        "platform verifier reported Revoked for {host}; webpki-roots fallback accepted the chain (likely missing OCSP AIA, e.g. Let's Encrypt R12)",
                    );
                    self.record_fallback();
                }
                result
            }
            Err(Error::General(ref msg))
                if msg.contains(NATIVE_VERIFIER_JNI_MARKER)
                    && self.trust_mode == KeTrustMode::PlatformWithFallback =>
            {
                let fallback = self.fallback()?;
                let result = fallback.verify_server_cert(
                    end_entity,
                    intermediates,
                    server_name,
                    ocsp_response,
                    now,
                );
                if result.is_ok() {
                    let host = host_for_log(server_name);
                    log::warn!(
                        target: "nts::hybrid_verifier",
                        "platform verifier failed via JNI for {host} ({msg}); webpki-roots fallback accepted the chain (likely R8 stripped org.rustls.platformverifier.* — see the nts plugin's android/consumer-rules.pro for the required keep rules)",
                    );
                    self.record_fallback();
                }
                result
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
    use super::*;
    use std::sync::Mutex;

    /// Configurable fake [`ServerCertVerifier`] for unit tests. A
    /// closure produces the result returned for each
    /// `verify_server_cert` call so a single test can synthesise
    /// `Revoked`, `General(JNI_MARKER)`, `Ok`, etc. on demand. The
    /// other trait methods are not exercised by `HybridVerifier`'s
    /// `verify_server_cert` path, so they are stubbed minimally.
    struct FakePlatform {
        result: Mutex<Box<dyn Fn() -> Result<ServerCertVerified, Error> + Send>>,
        call_count: AtomicU64,
    }

    impl std::fmt::Debug for FakePlatform {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.debug_struct("FakePlatform")
                .field("call_count", &self.call_count.load(Ordering::Relaxed))
                .finish_non_exhaustive()
        }
    }

    impl FakePlatform {
        fn new<F>(result: F) -> Arc<Self>
        where
            F: Fn() -> Result<ServerCertVerified, Error> + Send + 'static,
        {
            Arc::new(Self {
                result: Mutex::new(Box::new(result)),
                call_count: AtomicU64::new(0),
            })
        }
    }

    impl ServerCertVerifier for FakePlatform {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp_response: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, Error> {
            self.call_count.fetch_add(1, Ordering::Relaxed);
            (self.result.lock().expect("FakePlatform poisoned"))()
        }

        fn verify_tls12_signature(
            &self,
            _: &[u8],
            _: &CertificateDer<'_>,
            _: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Err(Error::PeerIncompatible(
                PeerIncompatible::Tls12NotOfferedOrEnabled,
            ))
        }

        fn verify_tls13_signature(
            &self,
            _: &[u8],
            _: &CertificateDer<'_>,
            _: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            Vec::new()
        }
    }

    /// Synthesise the input arguments for `verify_server_cert`.
    /// The leaf body is intentionally non-conformant (`b"leaf-stub"`):
    /// the fake platform never inspects it, and the fallback path is
    /// what we want to assert is *not* taken in `PlatformOnly` mode
    /// (so the webpki-roots verifier never sees these bytes either).
    /// The four tests that exercise the fallback path
    /// (`platform_with_fallback_{revoked,jni}_dual_failure_does_not_attribute`
    /// and `platform_with_fallback_{revoked,jni}_success_path_attributes_fallback`)
    /// rely on the verdict-shape rather than on a successful chain
    /// validation against `webpki-roots`: the dual-failure pair pins
    /// "result is no longer the platform's original error", and the
    /// success-path pair injects a fake fallback returning `Ok`
    /// directly (via `with_platform_and_fallback`), so a non-conformant
    /// leaf is sufficient for all four. The stub leaf failing the
    /// webpki-roots verifier is *load-bearing* for the `nts-7di`
    /// dual-failure assertion: it guarantees `fallback_count` stays
    /// at 0 on those paths, which transitively pins the absence of
    /// a `WARN nts::hybrid_verifier` line. The success-path pair
    /// bypasses webpki-roots entirely so this load-bearing property
    /// does not apply to them.
    fn dummy_args() -> (
        CertificateDer<'static>,
        Vec<CertificateDer<'static>>,
        ServerName<'static>,
        UnixTime,
    ) {
        let leaf = CertificateDer::from_slice(b"leaf-stub").into_owned();
        let server_name = ServerName::try_from("nts.example.test").expect("dns name");
        let now = UnixTime::since_unix_epoch(std::time::Duration::from_secs(1_700_000_000));
        (leaf, Vec::new(), server_name, now)
    }

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

    /// `nts-2lh` acceptance criterion: when constructed with
    /// `KeTrustMode::PlatformOnly`, the verifier propagates the
    /// platform's `Revoked` verdict verbatim. The `webpki-roots`
    /// fallback must not run, so `fallback_count` stays at 0.
    #[test]
    fn platform_only_propagates_revoked_without_fallback() {
        let fake = FakePlatform::new(|| Err(Error::InvalidCertificate(CertificateError::Revoked)));
        let verifier = HybridVerifier::with_platform(KeTrustMode::PlatformOnly, fake.clone());
        let (leaf, intermediates, server_name, now) = dummy_args();
        let result = verifier.verify_server_cert(&leaf, &intermediates, &server_name, &[], now);
        assert!(
            matches!(
                result,
                Err(Error::InvalidCertificate(CertificateError::Revoked))
            ),
            "expected Revoked propagated verbatim; got {result:?}",
        );
        assert_eq!(fake.call_count.load(Ordering::Relaxed), 1);
        assert_eq!(verifier.fallback_count(), 0);
    }

    /// `nts-2lh` acceptance criterion: when constructed with
    /// `KeTrustMode::PlatformOnly`, an `Error::General` carrying the
    /// JNI marker (R8 / ProGuard stripped the AAR's
    /// `org.rustls.platformverifier.*` glue) propagates verbatim
    /// without consulting `webpki-roots`.
    #[test]
    fn platform_only_propagates_jni_marker_without_fallback() {
        let fake = FakePlatform::new(|| {
            Err(Error::General(format!(
                "{NATIVE_VERIFIER_JNI_MARKER}: synthetic-jni-failure",
            )))
        });
        let verifier = HybridVerifier::with_platform(KeTrustMode::PlatformOnly, fake.clone());
        let (leaf, intermediates, server_name, now) = dummy_args();
        let result = verifier.verify_server_cert(&leaf, &intermediates, &server_name, &[], now);
        match result {
            Err(Error::General(msg)) => {
                assert!(
                    msg.contains(NATIVE_VERIFIER_JNI_MARKER),
                    "expected JNI-marker General propagated verbatim; got {msg:?}",
                );
            }
            other => panic!("expected Err(General(JNI marker)); got {other:?}"),
        }
        assert_eq!(fake.call_count.load(Ordering::Relaxed), 1);
        assert_eq!(verifier.fallback_count(), 0);
    }

    /// `nts-2lh` acceptance criterion: a non-fallback-eligible
    /// platform error (e.g. `UnknownIssuer`) propagates verbatim in
    /// both `PlatformWithFallback` and `PlatformOnly` modes; the
    /// `trust_mode` gating only affects the two curated arms.
    #[test]
    fn unknown_issuer_propagates_in_both_modes() {
        for trust_mode in [KeTrustMode::PlatformWithFallback, KeTrustMode::PlatformOnly] {
            let fake = FakePlatform::new(|| {
                Err(Error::InvalidCertificate(CertificateError::UnknownIssuer))
            });
            let verifier = HybridVerifier::with_platform(trust_mode, fake.clone());
            let (leaf, intermediates, server_name, now) = dummy_args();
            let result = verifier.verify_server_cert(&leaf, &intermediates, &server_name, &[], now);
            assert!(
                matches!(
                    result,
                    Err(Error::InvalidCertificate(CertificateError::UnknownIssuer))
                ),
                "{trust_mode:?}: expected UnknownIssuer verbatim; got {result:?}",
            );
            assert_eq!(verifier.fallback_count(), 0);
        }
    }

    /// `PlatformWithFallback` regression test plus `nts-7di`
    /// acceptance criterion: the historical safety net still fires
    /// for `Revoked` so that 3.1.0's strict `PlatformOnly` change
    /// does not accidentally regress the default behaviour, AND
    /// when the fallback itself also rejects the chain (the stub
    /// `b"leaf-stub"` will never validate against webpki-roots) no
    /// fallback is attributed: this verifier's per-instance
    /// `fallback_count()` stays at 0.
    ///
    /// Because the `log::warn!` and `record_fallback()` calls now
    /// share the same `if result.is_ok()` predicate (and
    /// `record_fallback()` bumps the per-instance counter and the
    /// process-global `TRUST_STATE.android_hybrid_fallback_count`
    /// in lockstep), the per-instance assertion below is a proxy
    /// for "no `WARN nts::hybrid_verifier` line was emitted on
    /// *this verifier's* verify call". The process-wide invariant
    /// `(grep -c WARN nts::hybrid_verifier) ==
    /// nts_trust_status().android_hybrid_fallback_count` also
    /// holds by construction, but is not what this single-verifier
    /// test directly asserts.
    ///
    /// We assert the fallback was *attempted* (the platform-result
    /// error transforms into a `webpki`-flavoured error rather than
    /// the original `Revoked`); the exact error shape from the
    /// webpki-roots verifier on the stub leaf is unimportant.
    #[test]
    fn platform_with_fallback_revoked_dual_failure_does_not_attribute() {
        let fake = FakePlatform::new(|| Err(Error::InvalidCertificate(CertificateError::Revoked)));
        let verifier =
            HybridVerifier::with_platform(KeTrustMode::PlatformWithFallback, fake.clone());
        let (leaf, intermediates, server_name, now) = dummy_args();
        let result = verifier.verify_server_cert(&leaf, &intermediates, &server_name, &[], now);
        assert!(
            !matches!(
                result,
                Err(Error::InvalidCertificate(CertificateError::Revoked))
            ),
            "fallback path was not taken: result still carries the platform's Revoked verdict ({result:?})",
        );
        assert_eq!(fake.call_count.load(Ordering::Relaxed), 1);
        assert_eq!(
            verifier.fallback_count(),
            0,
            "stub leaf cannot validate against webpki-roots, so the fallback failed; \
             `fallback_count` must stay at 0 to keep the warn/counter alignment \
             (no `WARN nts::hybrid_verifier` line is emitted on a failed fallback)",
        );
    }

    /// `nts-7di` acceptance criterion (JNI-marker arm): when the
    /// platform raises an `Error::General` carrying the JNI marker
    /// AND the webpki-roots fallback also rejects the chain, no
    /// fallback is attributed to this verifier (per-instance
    /// `fallback_count()` stays at 0) and — by virtue of sharing
    /// the `if result.is_ok()` predicate with `record_fallback()`
    /// — no `WARN nts::hybrid_verifier` line is emitted on this
    /// verifier's verify call. The result carries the fallback's
    /// webpki rejection, not the original `General` JNI error.
    #[test]
    fn platform_with_fallback_jni_dual_failure_does_not_attribute() {
        let fake = FakePlatform::new(|| {
            Err(Error::General(format!(
                "{NATIVE_VERIFIER_JNI_MARKER}: synthetic-jni-failure",
            )))
        });
        let verifier =
            HybridVerifier::with_platform(KeTrustMode::PlatformWithFallback, fake.clone());
        let (leaf, intermediates, server_name, now) = dummy_args();
        let result = verifier.verify_server_cert(&leaf, &intermediates, &server_name, &[], now);
        // The fallback path was taken: the result is no longer the
        // platform's JNI-marker `General` error.
        match &result {
            Err(Error::General(msg)) => {
                assert!(
                    !msg.contains(NATIVE_VERIFIER_JNI_MARKER),
                    "fallback path was not taken: result still carries the platform's JNI marker ({msg:?})",
                );
            }
            // Any non-`General` error (e.g. a webpki-flavoured
            // `InvalidCertificate` variant) is also acceptable — it
            // proves the fallback ran. Only an unexpected `Ok` would
            // be wrong here, and the stub leaf cannot validate.
            Ok(_) => panic!("stub leaf unexpectedly validated against webpki-roots"),
            Err(_) => {}
        }
        assert_eq!(fake.call_count.load(Ordering::Relaxed), 1);
        assert_eq!(
            verifier.fallback_count(),
            0,
            "stub leaf cannot validate against webpki-roots, so the fallback failed; \
             `fallback_count` must stay at 0 to keep the warn/counter alignment \
             (no `WARN nts::hybrid_verifier` line is emitted on a failed fallback)",
        );
    }

    /// `nts-6ff` acceptance criterion (Revoked arm): when the
    /// platform raises `Revoked` AND the (injected fake) fallback
    /// accepts the chain, the success path through the `Revoked`
    /// arm's `if result.is_ok()` block is exercised end-to-end:
    /// `verify_server_cert` returns `Ok`, the per-instance
    /// `fallback_count()` bumps to 1, and the process-global
    /// `TRUST_STATE.android_hybrid_fallback_count` increments in
    /// lockstep via `record_fallback()`.
    ///
    /// Companion to
    /// `platform_with_fallback_revoked_dual_failure_does_not_attribute`
    /// above; together they pin both branches of the shared
    /// `if result.is_ok()` predicate that gates the warn line and
    /// the counter bump in `verify_server_cert`.
    ///
    /// `TRUST_STATE` is process-global, so its post-condition is
    /// "incremented by at least 1" rather than an exact-value
    /// equality: other tests in the same `cargo test --lib` run
    /// may also bump it concurrently. The per-instance
    /// `fallback_count() == 1` is the strong, race-free assertion
    /// that the success path ran exactly once for *this* verifier.
    #[test]
    fn platform_with_fallback_revoked_success_path_attributes_fallback() {
        let platform =
            FakePlatform::new(|| Err(Error::InvalidCertificate(CertificateError::Revoked)));
        let fallback = FakePlatform::new(|| Ok(ServerCertVerified::assertion()));
        let trust_state_before = TRUST_STATE.snapshot().android_hybrid_fallback_count;
        let verifier = HybridVerifier::with_platform_and_fallback(
            KeTrustMode::PlatformWithFallback,
            platform.clone(),
            fallback.clone(),
        );
        let (leaf, intermediates, server_name, now) = dummy_args();
        let result = verifier.verify_server_cert(&leaf, &intermediates, &server_name, &[], now);
        assert!(result.is_ok(), "expected fallback to accept; got {result:?}");
        assert_eq!(platform.call_count.load(Ordering::Relaxed), 1);
        assert_eq!(fallback.call_count.load(Ordering::Relaxed), 1);
        assert_eq!(
            verifier.fallback_count(),
            1,
            "per-instance fallback_count must bump exactly once when the fallback accepts",
        );
        let trust_state_after = TRUST_STATE.snapshot().android_hybrid_fallback_count;
        assert!(
            trust_state_after > trust_state_before,
            "TRUST_STATE.android_hybrid_fallback_count must increment in lockstep with \
             record_fallback() (before: {trust_state_before}, after: {trust_state_after})",
        );
    }

    /// `nts-6ff` acceptance criterion (JNI-marker arm): the
    /// JNI-flavoured platform error is the second of the two
    /// fallback-eligible cases curated by `verify_server_cert`.
    /// When the (injected fake) fallback accepts the chain, the
    /// success path through the JNI-marker arm's `if result.is_ok()`
    /// block is exercised end-to-end. Same shape and assertions as
    /// the `Revoked` companion above.
    #[test]
    fn platform_with_fallback_jni_success_path_attributes_fallback() {
        let platform = FakePlatform::new(|| {
            Err(Error::General(format!(
                "{NATIVE_VERIFIER_JNI_MARKER}: synthetic-jni-failure",
            )))
        });
        let fallback = FakePlatform::new(|| Ok(ServerCertVerified::assertion()));
        let trust_state_before = TRUST_STATE.snapshot().android_hybrid_fallback_count;
        let verifier = HybridVerifier::with_platform_and_fallback(
            KeTrustMode::PlatformWithFallback,
            platform.clone(),
            fallback.clone(),
        );
        let (leaf, intermediates, server_name, now) = dummy_args();
        let result = verifier.verify_server_cert(&leaf, &intermediates, &server_name, &[], now);
        assert!(result.is_ok(), "expected fallback to accept; got {result:?}");
        assert_eq!(platform.call_count.load(Ordering::Relaxed), 1);
        assert_eq!(fallback.call_count.load(Ordering::Relaxed), 1);
        assert_eq!(
            verifier.fallback_count(),
            1,
            "per-instance fallback_count must bump exactly once when the fallback accepts",
        );
        let trust_state_after = TRUST_STATE.snapshot().android_hybrid_fallback_count;
        assert!(
            trust_state_after > trust_state_before,
            "TRUST_STATE.android_hybrid_fallback_count must increment in lockstep with \
             record_fallback() (before: {trust_state_before}, after: {trust_state_after})",
        );
    }
}
