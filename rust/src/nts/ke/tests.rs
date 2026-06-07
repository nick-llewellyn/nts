use super::*;
use crate::nts::records::record_type;
use crate::nts::test_helpers::rec;

mod tls_config {
    use super::*;

    /// RFC 8915 §3 forbids negotiating any TLS version below 1.3. The
    /// configuration constant must contain exactly one element pointing
    /// at `rustls::version::TLS13`. If a future edit slips `TLS12` back
    /// into this slice (or empties it, which would also be a downgrade
    /// vector since rustls would then fall through to the safe-default
    /// version set), this test fails before the change can land.
    #[test]
    fn tls_protocol_versions_are_tls13_only() {
        assert_eq!(
            TLS_PROTOCOL_VERSIONS.len(),
            1,
            "expected exactly one allowed TLS version"
        );
        let v = TLS_PROTOCOL_VERSIONS[0];
        assert_eq!(
            v.version,
            rustls::ProtocolVersion::TLSv1_3,
            "RFC 8915 §3 requires TLS 1.3 only; got {:?}",
            v.version,
        );
    }

    /// `build_tls_config` is the single funnel through which every
    /// handshake-bound `ClientConfig` flows. The integration property we
    /// can assert from outside the rustls crate (whose `versions` field
    /// is `pub(crate)`) is that the config builds without error and
    /// advertises the `ntske/1` ALPN identifier required by RFC 8915 §4.
    /// The TLS 1.3-only invariant is enforced by two upstream guards:
    /// the omission of the `rustls/tls12` Cargo feature in
    /// `rust/Cargo.toml` (build-time, removes TLS 1.2 code
    /// from the binary entirely) and the `TLS_PROTOCOL_VERSIONS`
    /// constant pinned by `tls_protocol_versions_are_tls13_only` above
    /// (in-code, refuses to negotiate TLS 1.2 even if a future edit
    /// re-adds the feature). Together those two checks make a runtime
    /// version probe redundant at this layer.
    #[test]
    fn build_tls_config_advertises_ntske_alpn() {
        let build =
            build_tls_config(KeTrustMode::PlatformWithFallback, None).expect("config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
    }

    /// `PlatformOnly` and `PlatformWithFallback` differ only on the
    /// `build_with_native_verifier` failure path: when the verifier
    /// constructs successfully (the host's normal case), both modes
    /// must produce a config that advertises the `ntske/1` ALPN and
    /// reports `KeTrustBackend::Platform`. The failure-path divergence
    /// (`PlatformOnly` → `KeError::TrustBackendUnavailable` vs
    /// `PlatformWithFallback` → `KeTrustBackend::WebpkiRoots`) is not
    /// reachable from a unit test on the host because
    /// `build_with_native_verifier` does not fail there; it requires
    /// the faux-responder fixture tracked separately.
    #[test]
    fn build_tls_config_platform_only_succeeds_when_verifier_constructs() {
        let build = build_tls_config(KeTrustMode::PlatformOnly, None).expect("config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
        assert_eq!(build.initial_backend, KeTrustBackend::Platform);
    }

    #[test]
    fn build_tls_config_bundled_only_succeeds() {
        let build = build_tls_config(KeTrustMode::BundledOnly, None).expect("config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
        assert_eq!(build.initial_backend, KeTrustBackend::WebpkiRoots);
    }

    #[test]
    fn build_tls_config_bundled_only_matches_webpki_only_protocol_options() {
        let build_bundled =
            build_tls_config(KeTrustMode::BundledOnly, None).expect("config builds");
        let expected_cfg = build_webpki_only_config(None).expect("webpki config builds");
        assert_eq!(
            build_bundled.config.alpn_protocols,
            expected_cfg.alpn_protocols
        );
        assert_eq!(
            build_bundled.config.enable_early_data,
            expected_cfg.enable_early_data
        );
        assert_eq!(build_bundled.config.enable_sni, expected_cfg.enable_sni);
    }

    const TEST_CERT_DER: &[u8] = &[
        0x30, 0x82, 0x03, 0x09, 0x30, 0x82, 0x01, 0xf1, 0xa0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x14,
        0x12, 0x7d, 0x2a, 0x02, 0xb0, 0xd5, 0x22, 0xe8, 0x68, 0x41, 0x59, 0x94, 0x03, 0xa4, 0xe6,
        0xb2, 0x3a, 0x12, 0x92, 0xdc, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
        0x01, 0x01, 0x0b, 0x05, 0x00, 0x30, 0x14, 0x31, 0x12, 0x30, 0x10, 0x06, 0x03, 0x55, 0x04,
        0x03, 0x0c, 0x09, 0x6c, 0x6f, 0x63, 0x61, 0x6c, 0x68, 0x6f, 0x73, 0x74, 0x30, 0x1e, 0x17,
        0x0d, 0x32, 0x36, 0x30, 0x35, 0x32, 0x34, 0x31, 0x39, 0x34, 0x31, 0x33, 0x37, 0x5a, 0x17,
        0x0d, 0x32, 0x37, 0x30, 0x35, 0x32, 0x34, 0x31, 0x39, 0x34, 0x31, 0x33, 0x37, 0x5a, 0x30,
        0x14, 0x31, 0x12, 0x30, 0x10, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x09, 0x6c, 0x6f, 0x63,
        0x61, 0x6c, 0x68, 0x6f, 0x73, 0x74, 0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a,
        0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
        0x30, 0x82, 0x01, 0x0a, 0x02, 0x82, 0x01, 0x01, 0x00, 0xe7, 0x3f, 0x42, 0x5f, 0x31, 0x09,
        0x30, 0x7a, 0x6a, 0x07, 0xdd, 0xa9, 0x52, 0xa1, 0x5d, 0xc8, 0x72, 0x27, 0xf2, 0x98, 0x92,
        0x9a, 0x8f, 0xcb, 0xfa, 0xea, 0xdd, 0x53, 0xe0, 0x14, 0x91, 0xb8, 0x14, 0xc1, 0xfc, 0xd0,
        0xfb, 0x24, 0xff, 0xc7, 0xce, 0xc5, 0x56, 0x24, 0xe4, 0xc8, 0x32, 0xf3, 0x78, 0xb5, 0x56,
        0x99, 0xca, 0x05, 0xb7, 0x4d, 0x3a, 0x1f, 0x20, 0x2d, 0x56, 0xdf, 0x7c, 0x4e, 0x86, 0x81,
        0x46, 0xf2, 0xe6, 0x9e, 0xa8, 0xfb, 0x30, 0xa4, 0xed, 0x5f, 0x81, 0xfe, 0x6d, 0x74, 0xa1,
        0xea, 0x6e, 0x03, 0x2d, 0xd1, 0x19, 0x71, 0x3b, 0xe4, 0xa1, 0x0f, 0x61, 0x7a, 0x53, 0x6a,
        0x33, 0xc1, 0xbb, 0x61, 0x1a, 0x50, 0xab, 0x6b, 0xcc, 0x67, 0x56, 0xca, 0xd6, 0x19, 0xfe,
        0x55, 0x78, 0xc2, 0x24, 0x2b, 0xe1, 0xcf, 0xd4, 0xea, 0x7f, 0x3e, 0xe3, 0x76, 0xc2, 0xaa,
        0x9f, 0xb2, 0x37, 0xe3, 0x38, 0xbe, 0x3d, 0xc8, 0x5b, 0xe3, 0xa3, 0x87, 0x12, 0xb5, 0x60,
        0xaf, 0x95, 0x02, 0xc2, 0x72, 0x1b, 0x21, 0x20, 0x93, 0xd7, 0x4b, 0xc8, 0xcf, 0x67, 0x32,
        0xe6, 0xd2, 0x7e, 0x9a, 0xdb, 0x33, 0x5e, 0xe8, 0x18, 0x28, 0x21, 0xf2, 0xba, 0x6f, 0x4c,
        0x5b, 0x56, 0xab, 0xa8, 0x27, 0x7c, 0x55, 0x37, 0x31, 0x7b, 0xea, 0x06, 0x02, 0xdd, 0xc7,
        0x0b, 0xef, 0x2d, 0x93, 0xca, 0x46, 0x5e, 0x42, 0xba, 0x59, 0xcb, 0xa4, 0x82, 0x9e, 0xa1,
        0x40, 0x8d, 0x66, 0x31, 0x0d, 0x7f, 0xc0, 0x56, 0xda, 0x3d, 0x25, 0xfe, 0xa0, 0x6e, 0xc9,
        0xb7, 0x72, 0x27, 0xe0, 0x3c, 0xdf, 0x36, 0xae, 0x16, 0xc7, 0x32, 0x6e, 0x0c, 0xe5, 0x65,
        0x15, 0xc7, 0x59, 0x58, 0x51, 0x79, 0xbd, 0x68, 0xa0, 0x21, 0xff, 0x6b, 0x2e, 0x48, 0x1c,
        0x74, 0xf9, 0x2b, 0x14, 0xbf, 0x07, 0x06, 0x41, 0x24, 0x7f, 0x02, 0x03, 0x01, 0x00, 0x01,
        0xa3, 0x53, 0x30, 0x51, 0x30, 0x1d, 0x06, 0x03, 0x55, 0x1d, 0x0e, 0x04, 0x16, 0x04, 0x14,
        0x98, 0xf2, 0xa5, 0x6e, 0x96, 0x93, 0xb1, 0x67, 0xa3, 0xd4, 0xfe, 0xc0, 0x94, 0x8a, 0x21,
        0xa3, 0x34, 0x98, 0x21, 0x65, 0x30, 0x1f, 0x06, 0x03, 0x55, 0x1d, 0x23, 0x04, 0x18, 0x30,
        0x16, 0x80, 0x14, 0x98, 0xf2, 0xa5, 0x6e, 0x96, 0x93, 0xb1, 0x67, 0xa3, 0xd4, 0xfe, 0xc0,
        0x94, 0x8a, 0x21, 0xa3, 0x34, 0x98, 0x21, 0x65, 0x30, 0x0f, 0x06, 0x03, 0x55, 0x1d, 0x13,
        0x01, 0x01, 0xff, 0x04, 0x05, 0x30, 0x03, 0x01, 0x01, 0xff, 0x30, 0x0d, 0x06, 0x09, 0x2a,
        0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b, 0x05, 0x00, 0x03, 0x82, 0x01, 0x01, 0x00,
        0x65, 0xb8, 0x9f, 0x95, 0x6a, 0x9d, 0x39, 0x0b, 0x7b, 0x1e, 0x69, 0x59, 0x59, 0xca, 0x16,
        0x68, 0x01, 0x91, 0xa0, 0x21, 0xba, 0xd0, 0xee, 0x8a, 0xef, 0x60, 0xbe, 0xf4, 0x3e, 0xb8,
        0x34, 0xc2, 0x9d, 0x45, 0x16, 0xcc, 0x92, 0x79, 0xd6, 0x1f, 0xcf, 0x64, 0xfd, 0x2a, 0x73,
        0x8a, 0xbc, 0xf6, 0x6a, 0x3a, 0xf4, 0x8a, 0xbd, 0xbd, 0xc2, 0x0c, 0x01, 0x8c, 0x00, 0x17,
        0x20, 0xf3, 0xaa, 0x13, 0xf8, 0xfc, 0xaf, 0xf4, 0x9d, 0x79, 0xe5, 0x0d, 0x03, 0xe3, 0xe6,
        0x1b, 0xe4, 0xbe, 0x4b, 0x91, 0x1a, 0x30, 0x6b, 0x92, 0x40, 0x40, 0xe4, 0x3c, 0xd9, 0x13,
        0x76, 0x3f, 0xa3, 0xdb, 0xb1, 0x98, 0x62, 0xc6, 0xca, 0xd1, 0x81, 0x4b, 0xaf, 0xd2, 0xad,
        0x95, 0xe0, 0x97, 0x92, 0x99, 0xbc, 0x0e, 0xcf, 0x1c, 0x2f, 0x39, 0x76, 0x25, 0x81, 0x36,
        0x1f, 0xb5, 0x5c, 0xd6, 0x51, 0x45, 0x8c, 0x01, 0xce, 0xd0, 0xe9, 0xd7, 0x9f, 0xe6, 0x00,
        0x08, 0xca, 0xd1, 0x52, 0xaf, 0x44, 0xa3, 0xfc, 0x3a, 0x88, 0x50, 0x6a, 0x66, 0xf1, 0x2a,
        0xaf, 0x34, 0x77, 0x39, 0x33, 0x4c, 0x17, 0x90, 0x28, 0xe6, 0x84, 0x86, 0x8e, 0xc6, 0xe3,
        0xf5, 0xfc, 0xd8, 0x16, 0xa6, 0xdb, 0xd6, 0x60, 0xa6, 0x21, 0x9e, 0x33, 0x7e, 0x45, 0xa5,
        0x95, 0x91, 0x85, 0x7d, 0x9f, 0x22, 0x47, 0x35, 0x36, 0x0d, 0x28, 0x4e, 0x64, 0xd5, 0xf2,
        0x89, 0x47, 0x27, 0xca, 0xe1, 0x29, 0x1c, 0xc5, 0x2d, 0xce, 0x73, 0x6a, 0x68, 0x55, 0x46,
        0xd1, 0xed, 0x59, 0xcb, 0x07, 0x95, 0x61, 0x8d, 0x61, 0x10, 0x33, 0x35, 0x21, 0x25, 0x79,
        0xde, 0xda, 0x84, 0x99, 0x14, 0x6b, 0x11, 0xf3, 0x0a, 0x9d, 0x85, 0xaa, 0xf0, 0xf2, 0x7c,
        0x9b, 0x62, 0x44, 0xab, 0xc3, 0xfd, 0xba, 0x19, 0xe8, 0xf7, 0xec, 0xc3, 0x30, 0xa2, 0xa9,
        0x9d,
    ];

    const TEST_CERT_PEM: &str = "-----BEGIN CERTIFICATE-----\n\
MIIDCTCCAfGgAwIBAgIUEn0qArDVIuhoQVmUA6TmsjoSktwwDQYJKoZIhvcNAQEL\n\
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDUyNDE5NDEzN1oXDTI3MDUy\n\
NDE5NDEzN1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF\n\
AAOCAQ8AMIIBCgKCAQEA5z9CXzEJMHpqB92pUqFdyHIn8piSmo/L+urdU+AUkbgU\n\
wfzQ+yT/x87FViTkyDLzeLVWmcoFt006HyAtVt98ToaBRvLmnqj7MKTtX4H+bXSh\n\
6m4DLdEZcTvkoQ9helNqM8G7YRpQq2vMZ1bK1hn+VXjCJCvhz9Tqfz7jdsKqn7I3\n\
4zi+Pchb46OHErVgr5UCwnIbISCT10vIz2cy5tJ+mtszXugYKCHyum9MW1arqCd8\n\
VTcxe+oGAt3HC+8tk8pGXkK6Wcukgp6hQI1mMQ1/wFbaPSX+oG7Jt3In4DzfNq4W\n\
xzJuDOVlFcdZWFF5vWigIf9rLkgcdPkrFL8HBkEkfwIDAQABo1MwUTAdBgNVHQ4E\n\
FgQUmPKlbpaTsWej1P7AlIohozSYIWUwHwYDVR0jBBgwFoAUmPKlbpaTsWej1P7A\n\
lIohozSYIWUwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAZbif\n\
lWqdOQt7HmlZWcoWaAGRoCG60O6K72C+9D64NMKdRRbMknnWH89k/Spzirz2ajr0\n\
ir29wgwBjAAXIPOqE/j8r/SdeeUNA+PmG+S+S5EaMGuSQEDkPNkTdj+j27GYYsbK\n\
0YFLr9KtleCXkpm8Ds8cLzl2JYE2H7Vc1lFFjAHO0OnXn+YACMrRUq9Eo/w6iFBq\n\
ZvEqrzR3OTNMF5Ao5oSGjsbj9fzYFqbb1mCmIZ4zfkWllZGFfZ8iRzU2DShOZNXy\n\
iUcnyuEpHMUtznNqaFVG0e1ZyweVYY1hEDM1ISV53tqEmRRrEfMKnYWq8PJ8m2JE\n\
q8P9uhno9+zDMKKpnQ==\n\
-----END CERTIFICATE-----";

    #[test]
    fn build_tls_config_custom_pem_succeeds() {
        let mode = KeTrustMode::Custom(CustomRootsBytes::new(TEST_CERT_PEM.as_bytes().to_vec()));
        let build = build_tls_config(mode, None).expect("custom PEM config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
        assert_eq!(build.initial_backend, KeTrustBackend::Custom);
    }

    #[test]
    fn build_tls_config_custom_der_succeeds() {
        let mode = KeTrustMode::Custom(CustomRootsBytes::new(TEST_CERT_DER.to_vec()));
        let build = build_tls_config(mode, None).expect("custom DER config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
        assert_eq!(build.initial_backend, KeTrustBackend::Custom);
    }

    #[test]
    fn build_tls_config_custom_malformed_pem_surfaces_diagnostic_substring() {
        let malformed_pem = "-----BEGIN CERTIFICATE-----\nnot-base64\n-----END CERTIFICATE-----";
        let mode = KeTrustMode::Custom(CustomRootsBytes::new(malformed_pem.as_bytes().to_vec()));
        let build = build_tls_config(mode, None);
        // Manual error extraction because TlsConfigBuild is not Debug
        let err = match build {
            Err(e) => e,
            Ok(_) => panic!("malformed PEM must fail"),
        };
        let msg = format!("{}", err);
        // Pin the stable substring required by nts-o88
        assert!(
            msg.contains("PEM certificate"),
            "expected 'PEM certificate' in error, got: {}",
            msg
        );
    }

    #[test]
    fn build_tls_config_custom_malformed_der_surfaces_diagnostic_substring() {
        // Not a PEM, so it falls through to DER parsing which fails in `roots.add(cert)`
        let mode = KeTrustMode::Custom(CustomRootsBytes::new(b"not-a-valid-cert-bytes".to_vec()));
        let build = build_tls_config(mode, None);
        let err = match build {
            Err(e) => e,
            Ok(_) => panic!("malformed DER must fail"),
        };
        let msg = format!("{}", err);
        // Pin the stable substring required by nts-o88
        assert!(
            msg.contains("custom root certificate"),
            "expected 'custom root certificate' in error, got: {}",
            msg
        );
    }

    #[test]
    fn build_tls_config_custom_empty_pem_surfaces_diagnostic_substring() {
        // Contains the marker so `is_pem` is true, but `pem_slice_iter` will
        // find no valid certificate blocks.
        let empty_pem = "text that contains -----BEGIN CERTIFICATE----- but no actual cert";
        let mode = KeTrustMode::Custom(CustomRootsBytes::new(empty_pem.as_bytes().to_vec()));
        let build = build_tls_config(mode, None);
        let err = match build {
            Err(e) => e,
            Ok(_) => panic!("empty PEM must fail"),
        };
        let msg = format!("{}", err);
        // Pin the stable substring required by nts-o88
        assert!(
            msg.contains("No custom certificates"),
            "expected 'No custom certificates' in error, got: {}",
            msg
        );
    }

    #[test]
    fn build_tls_config_custom_pem_with_pkcs7_preamble_succeeds() {
        // PKCS7-style preamble as `openssl pkcs7 -print_certs` would
        // emit it: attribute lines before the first BEGIN marker.
        // `pem_slice_iter` ignores bytes before the first recognised
        // PEM section, so detection only needs to notice the BEGIN
        // marker is present anywhere in the input — not at the start.
        let pem_with_preamble = format!(
            "subject=CN = localhost\nissuer=CN = localhost\n{}",
            TEST_CERT_PEM,
        );
        let mode =
            KeTrustMode::Custom(CustomRootsBytes::new(pem_with_preamble.as_bytes().to_vec()));
        let build = build_tls_config(mode, None).expect("custom PEM-with-preamble config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
        assert_eq!(build.initial_backend, KeTrustBackend::Custom);
    }

    #[test]
    fn build_tls_config_custom_pem_with_bag_attributes_preamble_succeeds() {
        // OpenSSL-style "Bag Attributes" preamble (common in PKCS12
        // exports), same shape as the PKCS7 case above.
        let pem_with_preamble = format!(
            "Bag Attributes\n    friendlyName: localhost\n    localKeyID: 01 02 03 04\n{}",
            TEST_CERT_PEM,
        );
        let mode =
            KeTrustMode::Custom(CustomRootsBytes::new(pem_with_preamble.as_bytes().to_vec()));
        let build = build_tls_config(mode, None).expect("custom PEM-with-bag-attrs config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
        assert_eq!(build.initial_backend, KeTrustBackend::Custom);
    }

    #[test]
    fn build_tls_config_custom_multi_cert_pem_bundle_parses_all_anchors() {
        // A valid certificate followed by a malformed one.
        // If the iterator incorrectly stopped after the first certificate,
        // `build_tls_config` would succeed. Success requires processing both blocks,
        // so the malformed second one must trigger an error. This verifies that
        // the iterator is fully consumed.
        let invalid_cert = "-----BEGIN CERTIFICATE-----\nINVALID-BASE64\n-----END CERTIFICATE-----";
        let bundle = format!("{}\n\n{}", TEST_CERT_PEM, invalid_cert);
        let mode = KeTrustMode::Custom(CustomRootsBytes::new(bundle.as_bytes().to_vec()));

        let err = build_tls_config(mode, None)
            .expect_err("multi-cert bundle with malformed second cert should fail");
        let msg = format!("{}", err);
        assert!(
            msg.contains("Failed to parse PEM certificate"),
            "error should mention PEM failure: {}",
            msg
        );
    }

    #[test]
    fn test_custom_roots_bytes_redaction() {
        let bytes = b"secret-certificate-data".to_vec();
        let len = bytes.len();
        let custom = CustomRootsBytes::new(bytes);
        let debug = format!("{:?}", custom);
        assert!(debug.contains(&format!("<REDACTED: {} bytes>", len)));
        assert!(!debug.contains("secret-certificate-data"));
    }

    #[test]
    fn test_custom_roots_bytes_as_slice() {
        let bytes = b"cert-data".to_vec();
        let custom = CustomRootsBytes::new(bytes.clone());
        assert_eq!(custom.as_slice(), bytes.as_slice());
    }
}

mod request_build {
    use super::*;

    #[test]
    fn build_request_emits_expected_bytes() {
        // NextProtocol(NTPv4) crit + AeadAlgorithm(SIV-256) crit + EOM crit.
        // 4-byte hdr + 2 (proto) | 4 + 2 (aead) | 4 (eom) = 16 octets.
        let bytes = build_request(&[aead::AES_SIV_CMAC_256]);
        let expected = vec![
            0x80,
            record_type::NEXT_PROTOCOL as u8,
            0x00,
            0x02,
            0x00,
            0x00, // type 1, NTPv4
            0x80,
            record_type::AEAD_ALGORITHM as u8,
            0x00,
            0x02,
            0x00,
            0x0F, // type 4, SIV-256
            0x80,
            record_type::END_OF_MESSAGE as u8,
            0x00,
            0x00, // type 0
        ];
        assert_eq!(bytes, expected);
    }

    /// `build_request` must serialise multi-AEAD offers in the order the
    /// caller specified — the AeadAlgorithm record is a `Vec<u16>` whose
    /// position-zero element is the client's most-preferred algorithm
    /// (RFC 8915 §4.1.5). This test pins that ordering as a regression guard
    /// since the KE driver's preference is set by `establish_session` in
    /// `api/nts.rs` and we don't want a future refactor to silently flip it.
    #[test]
    fn build_request_preserves_aead_preference_order() {
        let bytes = build_request(&[aead::AES_SIV_CMAC_256, aead::AES_128_GCM_SIV]);
        // Body of the AeadAlgorithm record is at offset 10 (4 hdr + 2 body for
        // NextProtocol + 4 hdr) — easier to parse it back than count by hand.
        let records = parse_message(&bytes).unwrap();
        let aead_record = records
            .iter()
            .find_map(|r| match &r.kind {
                RecordKind::AeadAlgorithm(v) => Some(v.clone()),
                _ => None,
            })
            .expect("AeadAlgorithm record present");
        assert_eq!(
            aead_record,
            vec![aead::AES_SIV_CMAC_256, aead::AES_128_GCM_SIV]
        );
    }
}

mod aead_negotiation {
    use super::*;

    #[test]
    fn exporter_context_matches_rfc_8915() {
        // RFC 8915 §5.1: 5 octets — proto (NTPv4=0), AEAD ID, direction byte.
        assert_eq!(
            exporter_context(aead::AES_SIV_CMAC_256, false),
            [0, 0, 0, 15, 0]
        );
        assert_eq!(
            exporter_context(aead::AES_SIV_CMAC_256, true),
            [0, 0, 0, 15, 1]
        );
        assert_eq!(
            exporter_context(aead::AES_SIV_CMAC_384, false),
            [0, 0, 0, 16, 0]
        );
        assert_eq!(
            exporter_context(aead::AES_SIV_CMAC_512, true),
            [0, 0, 0, 17, 1]
        );
    }

    #[test]
    fn aead_key_lengths_match_rfc_8915() {
        assert_eq!(aead_key_len(aead::AES_SIV_CMAC_256), Some(32));
        // RFC 8915 §5.1 — AES-SIV-CMAC-512 (AEAD ID 17) splits a
        // 64-byte key into a 32-byte CMAC-AES-256 subkey and a
        // 32-byte AES-256 encryption key.
        assert_eq!(aead_key_len(aead::AES_SIV_CMAC_512), Some(64));
        // RFC 8452 §4 — AES-128-GCM-SIV uses a 128-bit key.
        assert_eq!(aead_key_len(aead::AES_128_GCM_SIV), Some(16));
        // SIV-CMAC-384 is a valid IANA registry entry (RFC 8915
        // §5.1) but is not in the supported set: the AEAD
        // constructor in `crate::nts::aead` does not implement it,
        // so listing it here would let `validate_response` accept
        // an offered AEAD that exporter-key derivation immediately
        // fails on. The `aead_key_len_agrees_with_constructor`
        // test below pins the cross-surface invariant.
        assert_eq!(aead_key_len(aead::AES_SIV_CMAC_384), None);
        assert_eq!(aead_key_len(0xFFFF), None);
        assert_eq!(aead_key_len(14), None);
    }

    /// Pin the cross-surface invariant documented on
    /// [`super::OFFERED_AEAD_IDS`]: every IANA AEAD ID that
    /// [`super::aead_key_len`] reports as supported must also be
    /// constructible by `AeadKey::from_keying_material` in
    /// `crate::nts::aead`, and every ID that the constructor
    /// rejects must also be absent from the lookup table. Drift
    /// between the two surfaces would let `validate_response`
    /// accept a server-picked AEAD that `establish_session` (in
    /// `rust/src/api/nts.rs`) then `map_err`s into
    /// `NtsError::Internal("KE produced unusable … key: …")` —
    /// confusing for the caller because the handshake itself
    /// succeeded — instead of the correct
    /// `KeError::UnsupportedAead(id)`.
    ///
    /// The walked set covers the full IANA SIV-CMAC family (15-17)
    /// plus AES-128-GCM-SIV (30) plus a handful of out-of-registry
    /// IDs (0, 14, 31, 0xFFFF) so both arms of the invariant
    /// (positive and negative) are pinned.
    #[test]
    fn aead_key_len_agrees_with_constructor() {
        use crate::nts::aead::{AeadError, AeadKey};
        for id in [
            aead::AES_SIV_CMAC_256, // 15 — both Some / Ok
            aead::AES_SIV_CMAC_384, // 16 — both None / UnsupportedAlgorithm
            aead::AES_SIV_CMAC_512, // 17 — both None / UnsupportedAlgorithm
            aead::AES_128_GCM_SIV,  // 30 — both Some / Ok
            0,
            14,
            31,
            0xFFFF,
        ] {
            match aead_key_len(id) {
                Some(len) => {
                    // Positive arm: the table reports a length, so
                    // the constructor must accept a buffer of that
                    // exact length.
                    let key_buf = vec![0u8; len];
                    AeadKey::from_keying_material(id, &key_buf).unwrap_or_else(|e| {
                        panic!(
                            "aead_key_len({id}) = Some({len}) but constructor rejected \
                             a {len}-byte buffer with {e:?} — the lookup table and the \
                             AEAD constructor must agree on the supported set",
                        )
                    });
                }
                None => {
                    // Negative arm: the table rejects the ID, so the
                    // constructor must also reject it — *specifically*
                    // with `UnsupportedAlgorithm(id)`, not any other
                    // error. Asserting the variant (rather than just
                    // `is_err()`) closes the drift Copilot flagged on
                    // PR #46: a hypothetical future arm in
                    // `from_keying_material` that requires a
                    // non-64-byte key would return
                    // `Err(InvalidKeyLength { .. })` against any 64-
                    // byte probe buffer, satisfying a loose `is_err()`
                    // check while leaving the table-vs-constructor
                    // drift unobserved.
                    let probe = vec![0u8; 64];
                    match AeadKey::from_keying_material(id, &probe) {
                        Err(AeadError::UnsupportedAlgorithm(reported)) => {
                            assert_eq!(
                                reported, id,
                                "constructor rejected ID {id} but reported \
                                 UnsupportedAlgorithm({reported}) — variant payload \
                                 must echo the ID under test",
                            );
                        }
                        other => panic!(
                            "aead_key_len({id}) = None but constructor returned {other:?} \
                             — expected Err(UnsupportedAlgorithm({id})); a different error \
                             variant means the constructor does recognise the ID, so the \
                             lookup table is missing an entry",
                        ),
                    }
                }
            }
        }
    }

    /// Stronger pin specifically for the offered-list surface:
    /// every AEAD ID that `establish_session` is currently
    /// configured to offer to the server (via
    /// [`super::OFFERED_AEAD_IDS`]) must round-trip cleanly through
    /// both [`super::aead_key_len`] and the AEAD constructor, so
    /// the actual handshake path can never reach the
    /// `NtsError::Internal("KE produced unusable … key")` branch
    /// (in `rust/src/api/nts.rs::establish_session`) on a server
    /// pick from the offered list.
    #[test]
    fn offered_aead_ids_are_supported_end_to_end() {
        use crate::nts::aead::AeadKey;
        for &id in OFFERED_AEAD_IDS {
            let len = aead_key_len(id)
                .unwrap_or_else(|| panic!("offered AEAD {id} has no aead_key_len entry"));
            let key_buf = vec![0u8; len];
            AeadKey::from_keying_material(id, &key_buf)
                .unwrap_or_else(|e| panic!("offered AEAD {id} is not constructible: {e:?}"));
        }
    }
}

mod validate_response {
    use super::*;

    fn well_formed_response() -> Vec<Record> {
        vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(
                true,
                RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            ),
            rec(
                false,
                RecordKind::NewCookie(Zeroizing::new(vec![1, 2, 3, 4, 5, 6, 7, 8])),
            ),
            rec(
                false,
                RecordKind::NewCookie(Zeroizing::new(vec![9, 10, 11, 12, 13, 14, 15, 16])),
            ),
            rec(true, RecordKind::EndOfMessage),
        ]
    }

    #[test]
    fn validate_response_accepts_minimal_well_formed() {
        let records = well_formed_response();
        let p = validate_response("time.example.com", &[aead::AES_SIV_CMAC_256], &records).unwrap();
        assert_eq!(p.aead_id, aead::AES_SIV_CMAC_256);
        assert_eq!(p.cookies.len(), 2);
        assert_eq!(p.ntpv4_host, "time.example.com");
        assert_eq!(p.ntpv4_port, 123);
        assert!(p.warnings.is_empty());
    }

    #[test]
    fn validate_response_honors_server_and_port_override() {
        let mut records = well_formed_response();
        records.insert(
            2,
            rec(false, RecordKind::Server("ntp.alt.example".to_owned())),
        );
        records.insert(3, rec(false, RecordKind::Port(4123)));
        let p = validate_response("ke.example.com", &[aead::AES_SIV_CMAC_256], &records).unwrap();
        assert_eq!(p.ntpv4_host, "ntp.alt.example");
        assert_eq!(p.ntpv4_port, 4123);
    }

    #[test]
    fn validate_response_propagates_server_error() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(true, RecordKind::Error(ErrorCode::InternalServerError)),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::ServerError(ErrorCode::InternalServerError)) => {}
            other => panic!("expected ServerError(InternalServerError), got {other:?}"),
        }
    }

    #[test]
    fn validate_response_rejects_unknown_critical() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(
                true,
                RecordKind::Unknown {
                    record_type: 0x4242,
                    body: vec![],
                },
            ),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::UnknownCritical(0x4242)) => {}
            other => panic!("expected UnknownCritical, got {other:?}"),
        }
    }

    #[test]
    fn validate_response_rejects_no_common_protocol() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![0xFFFF])),
            rec(
                true,
                RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            ),
            rec(false, RecordKind::NewCookie(Zeroizing::new(vec![0; 8]))),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NoCommonProtocol) => {}
            other => panic!("expected NoCommonProtocol, got {other:?}"),
        }
    }

    #[test]
    fn validate_response_rejects_unsupported_aead() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(true, RecordKind::AeadAlgorithm(vec![999])),
            rec(false, RecordKind::NewCookie(Zeroizing::new(vec![0; 8]))),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::UnsupportedAead(999)) => {}
            other => panic!("expected UnsupportedAead(999), got {other:?}"),
        }
    }

    #[test]
    fn validate_response_rejects_no_cookies() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(
                true,
                RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            ),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NoCookies) => {}
            other => panic!("expected NoCookies, got {other:?}"),
        }
    }

    /// RFC 8915 §4.1.5 — the AEAD Algorithm Negotiation record MUST
    /// appear exactly once. The codec layer (`parse_message`) is
    /// happy to return two AeadAlgorithm records in the same
    /// message; the validator must refuse them, otherwise `find_map`
    /// would silently take the first occurrence and an on-path tamper
    /// could inject a duplicate to mask a genuine downgrade. Mirrors
    /// the request-side guard ntpd-rs ships in
    /// `ntp-proto/src/nts/messages.rs::test_request_basic_reject_multiple`
    /// (v1.7.2).
    #[test]
    fn validate_response_rejects_duplicate_aead_algorithm() {
        let mut records = well_formed_response();
        // Insert a second critical AeadAlgorithm record before the EOM
        // (which lives at the tail in `well_formed_response`). The
        // duplicate is materially equivalent to the first, so the only
        // signal driving the rejection is the duplicate-record count.
        let eom_pos = records.len() - 1;
        records.insert(
            eom_pos,
            rec(
                true,
                RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            ),
        );
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::DuplicateAeadAlgorithm) => {}
            other => panic!("expected DuplicateAeadAlgorithm, got {other:?}"),
        }
    }

    /// RFC 8915 §4.1.2 — symmetric to the AeadAlgorithm case above;
    /// duplicate NextProtocol records must short-circuit the
    /// handshake before either NextProtocol value is honoured.
    /// Mirrors the request-side guard ntpd-rs ships in
    /// `ntp-proto/src/nts/messages.rs::test_request_basic_reject_multiple`
    /// (v1.7.2).
    #[test]
    fn validate_response_rejects_duplicate_next_protocol() {
        let mut records = well_formed_response();
        let eom_pos = records.len() - 1;
        records.insert(
            eom_pos,
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
        );
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::DuplicateNextProtocol) => {}
            other => panic!("expected DuplicateNextProtocol, got {other:?}"),
        }
    }

    /// An Error record appearing alongside otherwise-valid response
    /// records must short-circuit the handshake. RFC 8915 is silent
    /// on the precise interaction (the spec treats Error as the
    /// server's signal to decline the request, not as a record that
    /// can co-occur with a successful negotiation), but the safe
    /// behaviour is to surface the server's error code rather than
    /// silently completing key export against a response the server
    /// has explicitly disclaimed. Pinned here as `ServerError(code)`
    /// (the existing arm in the per-record loop already catches it
    /// regardless of position or critical bit) — the choice is to
    /// preserve the server's diagnostic code rather than collapse
    /// onto a generic `MalformedResponse` so the Dart side can
    /// surface "server said error N" verbatim. Mirrors the
    /// request-side guard ntpd-rs ships in
    /// `ntp-proto/src/nts/messages.rs::test_request_basic_reject_problematic`
    /// (v1.7.2).
    #[test]
    fn validate_response_rejects_extra_error_record_after_handshake() {
        let mut records = well_formed_response();
        // Inject a non-critical Error record immediately before the
        // EOM. The Error variant is RFC 8915 §4.1.3 record type 2
        // with a u16 payload; using `0xBEEF` as an arbitrary
        // server-defined code so the test pins both the rejection
        // *and* the round-trip of the code through `ServerError`.
        let eom_pos = records.len() - 1;
        records.insert(
            eom_pos,
            rec(false, RecordKind::Error(ErrorCode::Unknown(0xBEEF))),
        );
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::ServerError(ErrorCode::Unknown(0xBEEF))) => {}
            other => panic!("expected ServerError(Unknown(0xBEEF)), got {other:?}"),
        }
    }

    /// RFC 8915 §4.1.2 — a NextProtocol record without the Critical bit
    /// is a protocol violation and must be rejected before any further
    /// processing of the response. Crafted response is otherwise
    /// well-formed (correct kind, NTPv4 protocol ID, valid AEAD, present
    /// cookies) so the only signal driving the rejection is the cleared
    /// C bit on the first record.
    #[test]
    fn validate_response_rejects_non_critical_next_protocol() {
        let mut records = well_formed_response();
        records[0] = rec(false, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4]));
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NonCriticalNextProtocol) => {}
            other => panic!("expected NonCriticalNextProtocol, got {other:?}"),
        }
    }

    /// RFC 8915 §4.1.5 — symmetric to the NextProtocol case above; an
    /// AeadAlgorithm record without the Critical bit must short-circuit
    /// the handshake before key export.
    #[test]
    fn validate_response_rejects_non_critical_aead_algorithm() {
        let mut records = well_formed_response();
        records[1] = rec(
            false,
            RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
        );
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NonCriticalAeadAlgorithm) => {}
            other => panic!("expected NonCriticalAeadAlgorithm, got {other:?}"),
        }
    }

    /// When both the NextProtocol and AeadAlgorithm records lack the
    /// Critical bit, the NextProtocol violation must surface first —
    /// it appears earlier in `validate_response` and rejecting on it
    /// keeps the diagnostic deterministic for callers that pattern-match
    /// on the variant for retry/backoff classification.
    #[test]
    fn validate_response_rejects_non_critical_next_protocol_first() {
        let mut records = well_formed_response();
        records[0] = rec(false, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4]));
        records[1] = rec(
            false,
            RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
        );
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NonCriticalNextProtocol) => {}
            other => panic!("expected NonCriticalNextProtocol, got {other:?}"),
        }
    }

    /// When the client offers `[SIV-CMAC-256, AES-128-GCM-SIV]` and the server
    /// echoes a single AeadAlgorithm record, `validate_response` must accept
    /// whichever ID the server actually picked. The KE driver itself does not
    /// re-prioritise — that's the server's prerogative per RFC 8915 §4.1.5 —
    /// but it must not reject either of the offered IDs.
    #[test]
    fn validate_response_accepts_either_offered_aead() {
        let offered = [aead::AES_SIV_CMAC_256, aead::AES_128_GCM_SIV];

        let mut server_picks_siv = well_formed_response();
        if let RecordKind::AeadAlgorithm(v) = &mut server_picks_siv[1].kind {
            *v = vec![aead::AES_SIV_CMAC_256];
        }
        let p1 = validate_response("h", &offered, &server_picks_siv).unwrap();
        assert_eq!(p1.aead_id, aead::AES_SIV_CMAC_256);

        let mut server_picks_gcm = well_formed_response();
        if let RecordKind::AeadAlgorithm(v) = &mut server_picks_gcm[1].kind {
            *v = vec![aead::AES_128_GCM_SIV];
        }
        let p2 = validate_response("h", &offered, &server_picks_gcm).unwrap();
        assert_eq!(p2.aead_id, aead::AES_128_GCM_SIV);
    }

    /// RFC 8915 §4.1.5 — the `AeadAlgorithm` record may carry an empty
    /// body as a server-side refusal signal ("the server is unwilling
    /// to use any of the client-offered algorithms"). That shape is
    /// materially different from a fully missing record: the former
    /// is a policy mismatch worth surfacing to the user, the latter
    /// is a non-conforming server. `validate_response` must distinguish
    /// the two via dedicated error variants.
    #[test]
    fn validate_response_distinguishes_empty_aead_from_missing() {
        let mut records = well_formed_response();
        if let RecordKind::AeadAlgorithm(v) = &mut records[1].kind {
            v.clear();
        }
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::AeadNegotiationRefused) => {}
            other => panic!("expected AeadNegotiationRefused, got {other:?}"),
        }

        // Sanity arm: fully removing the record still yields the
        // pre-existing `MissingAead` variant — the two shapes do not
        // collide.
        let mut without_aead = well_formed_response();
        without_aead.remove(1);
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &without_aead) {
            Err(KeError::MissingAead) => {}
            other => panic!("expected MissingAead, got {other:?}"),
        }
    }

    /// RFC 8915 §4.1.5 still requires the Critical bit on the
    /// `AeadAlgorithm` record even when its body is empty. The
    /// non-critical violation must surface before the empty-body
    /// refusal so the diagnostic remains deterministic: an attacker
    /// who can strip the Critical bit must not be able to mask the
    /// shape-level violation behind a content-level signal.
    #[test]
    fn validate_response_non_critical_aead_precedes_empty_body() {
        let mut records = well_formed_response();
        records[1] = rec(false, RecordKind::AeadAlgorithm(vec![]));
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NonCriticalAeadAlgorithm) => {}
            other => panic!("expected NonCriticalAeadAlgorithm, got {other:?}"),
        }
    }

    /// RFC 8915 §4.1.4 — unknown non-critical records MUST be ignored
    /// (the response remains valid). The diagnostic-logging change in
    /// nts-b8x must not alter that behaviour: a well-formed response
    /// carrying a single unknown non-critical record must still parse
    /// to the same `KeOutcomePartial` it would produce without the
    /// extra record present.
    #[test]
    fn validate_response_ignores_unknown_non_critical_record() {
        let mut records = well_formed_response();
        // Insert just before the EOM (last element).
        let eom_pos = records.len() - 1;
        records.insert(
            eom_pos,
            rec(
                false,
                RecordKind::Unknown {
                    record_type: 0x4242,
                    body: vec![0xAA, 0xBB, 0xCC],
                },
            ),
        );
        let p =
            validate_response("h", &[aead::AES_SIV_CMAC_256], &records).expect("response valid");
        assert_eq!(p.aead_id, aead::AES_SIV_CMAC_256);
        assert_eq!(p.cookies.len(), 2);
    }

    /// RFC 8915 §4.1.3 requires the Critical bit on the `Error`
    /// record. A non-critical `Error` record is a protocol violation,
    /// but the fail-safe contract is preserved — the server is still
    /// telling us something went wrong, so the response is still
    /// failed with `ServerError(code)`. The deviation is reported via
    /// the log channel rather than promoted into a distinct error
    /// variant; this test pins the fail-safe contract.
    #[test]
    fn validate_response_honors_non_critical_error_record() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(false, RecordKind::Error(ErrorCode::BadRequest)),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::ServerError(ErrorCode::BadRequest)) => {}
            other => panic!("expected ServerError(BadRequest), got {other:?}"),
        }
    }
}

mod connect {
    use super::*;

    /// `connect_with_timeout` must honour the caller's deadline when the
    /// destination is blackholed. RFC 5737 reserves `192.0.2.0/24`
    /// (TEST-NET-1) for documentation; no public network advertises a
    /// route for it, so a SYN to `192.0.2.1:4460` either gets dropped on
    /// the wire (deadline fires mid-SYN) or rejected locally with a
    /// routing error (`EHOSTUNREACH` / `ENETUNREACH`). Both outcomes
    /// satisfy the contract — what we assert is that the call returns
    /// well inside the OS-default ~75 s connect window, which is the
    /// regression this helper exists to prevent. When the deadline
    /// itself fires, the result must be
    /// `KeError::PhaseTimeout(KeTimeoutPhase::Connect)` so the
    /// `From<KeError> for NtsError` mapping produces
    /// `NtsError::Timeout(TimeoutPhase::Connect)` rather than a
    /// generic `Network` error.
    #[test]
    fn connect_with_timeout_respects_budget_for_unroutable_ip() {
        let budget = Duration::from_millis(500);
        let started = Instant::now();
        let result = connect_with_timeout("192.0.2.1", 4460, Some(budget));
        let elapsed = started.elapsed();

        let err = result.expect_err("connecting to 192.0.2.1:4460 must fail");

        // The cap is generous enough to absorb scheduling jitter on slow
        // CI runners while still being orders of magnitude tighter than
        // the OS-default connect timeout this code path replaces.
        let cap = Duration::from_secs(5);
        assert!(
            elapsed < cap,
            "connect took {elapsed:?} (> {cap:?}); OS-default connect \
             timeout is leaking through (err = {err:?})",
        );

        // When the deadline elapsed (rather than the OS rejecting
        // immediately), the variant must be PhaseTimeout(Connect) so
        // downstream error mapping produces NtsError::Timeout(Connect).
        if elapsed >= budget {
            assert!(
                matches!(err, KeError::PhaseTimeout(KeTimeoutPhase::Connect)),
                "deadline elapsed after {elapsed:?} but error was \
                 {err:?}; would not surface as NtsError::Timeout(Connect)",
            );
        }
    }

    /// Slow-DNS regression guard for [`connect_with_timeout`]. Injects a
    /// resolver that blocks past the budget and asserts the call returns
    /// `KeError::PhaseTimeout(DnsTimeout)` well inside the cap.
    /// Pinning the variant here is what the `From<KeError> for
    /// NtsError` mapping in `api/nts.rs` relies on to surface stalled
    /// `getaddrinfo` as `NtsError::Timeout(DnsTimeout)` rather than as
    /// a generic network error. Companion to `dns::tests::slow_resolver_*`
    /// and `api::nts::tests::bind_connected_udp_surfaces_slow_dns_*`;
    /// see `nts-6ka` for the full set of injection points.
    #[test]
    fn connect_with_timeout_surfaces_slow_dns_as_timed_out() {
        let budget = Duration::from_millis(50);
        let started = Instant::now();
        // Generous cap so this test stays isolated from any other
        // test in the suite that holds slots in the global resolver
        // pool. The test is pinning the slow-DNS → DnsTimeout mapping,
        // not the cap-exhaustion path (which has dedicated coverage in
        // `dns::tests::cap_reached_returns_would_block`).
        let result =
            connect_with_timeout_using("ignored.invalid", 0, Some(budget), 64, |_host, _port| {
                std::thread::sleep(Duration::from_secs(2));
                Ok(vec![SocketAddr::from(([127, 0, 0, 1], 0))])
            });
        let elapsed = started.elapsed();

        let err = result.expect_err("slow resolver must trip the deadline");
        assert!(
            matches!(err, KeError::PhaseTimeout(KeTimeoutPhase::DnsTimeout)),
            "slow-DNS path must surface as PhaseTimeout(DnsTimeout), got {err:?}",
        );
        let cap = budget * 5;
        assert!(
            elapsed < cap,
            "connect_with_timeout took {elapsed:?} (> {cap:?}); \
             resolver budget did not propagate",
        );
    }

    /// Companion to the `Deadline` unit tests: drives the same
    /// blackholed-IP scenario as
    /// `connect_with_timeout_respects_budget_for_unroutable_ip`,
    /// but through `connect_with_deadline_using` directly to prove the
    /// new entry point honours an externally-supplied deadline (the
    /// shape `perform_handshake` passes in). Without this, a future
    /// edit could accidentally regress the connect helper to use the
    /// caller's original duration on each iteration.
    #[test]
    fn connect_with_deadline_respects_external_deadline_for_unroutable_ip() {
        let budget = Duration::from_millis(500);
        let deadline = Some(Deadline::new(budget));
        let started = Instant::now();
        let result = connect_with_deadline_using(
            "192.0.2.1",
            4460,
            deadline,
            crate::nts::dns::DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS,
            system_lookup,
        );
        let elapsed = started.elapsed();
        assert!(result.is_err(), "connecting to TEST-NET-1 must fail");
        let cap = Duration::from_secs(5);
        assert!(
            elapsed < cap,
            "connect_with_deadline_using took {elapsed:?} (> {cap:?}); \
             OS-default connect timeout is leaking through",
        );
    }
}

mod deadline {
    use super::*;

    /// Pins the `Deadline::remaining` saturation contract: once the
    /// anchored instant has passed, `remaining()` reports zero rather
    /// than panicking on the underlying `Duration` subtraction.
    /// `apply_to` and the connect/read paths in `perform_handshake`
    /// rely on `is_zero()` as the "deadline elapsed" signal, so
    /// regressing this would silently re-enable budget overshoot.
    #[test]
    fn deadline_remaining_saturates_at_zero_after_expiry() {
        let d = Deadline::new(Duration::from_micros(1));
        std::thread::sleep(Duration::from_millis(10));
        assert!(
            d.remaining().is_zero(),
            "expired deadline must saturate at zero, got {:?}",
            d.remaining(),
        );
    }

    /// `Deadline::apply_to` is the funnel that translates "budget
    /// elapsed" into the `io::Error` shape the `From<KeError> for
    /// NtsError` mapping in `api/nts.rs` recognises as
    /// `NtsError::Timeout`. Any other `ErrorKind` would surface as
    /// `NtsError::Network`, which is exactly the regression this
    /// helper exists to prevent.
    #[test]
    fn deadline_apply_to_returns_timed_out_when_expired() {
        let d = Deadline::new(Duration::from_micros(1));
        std::thread::sleep(Duration::from_millis(10));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let tcp = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let err = d.apply_to(&tcp).expect_err("expired deadline must fail");
        assert_eq!(err.kind(), std::io::ErrorKind::TimedOut);
    }

    /// `apply_to` must shrink the socket's read/write timeouts to the
    /// remaining budget (not re-arm the original duration). Pinning
    /// both bounds — strictly positive and bounded above by the
    /// configured budget — guarantees that subsequent socket syscalls
    /// will trip well before the original `req.timeout` could have
    /// allowed them to.
    #[test]
    fn deadline_apply_to_sets_socket_timeouts_within_remaining_budget() {
        let budget = Duration::from_millis(500);
        let d = Deadline::new(budget);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let tcp = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        d.apply_to(&tcp).expect("non-zero remaining");
        let read_t = tcp.read_timeout().unwrap().expect("read timeout set");
        let write_t = tcp.write_timeout().unwrap().expect("write timeout set");
        assert!(
            read_t > Duration::ZERO && read_t <= budget,
            "read timeout {read_t:?} must be in (0, {budget:?}]",
        );
        assert!(
            write_t > Duration::ZERO && write_t <= budget,
            "write timeout {write_t:?} must be in (0, {budget:?}]",
        );
    }

    /// Phase-aware variant of `apply_to`. Translates an expired
    /// budget directly to `KeError::PhaseTimeout(phase)` so the
    /// phase tag survives without round-tripping through
    /// `io::ErrorKind::TimedOut`. Pinning every supported phase here
    /// ensures a future edit that hard-codes a single phase can't
    /// silently regress the attribution.
    #[test]
    fn deadline_apply_to_with_phase_returns_phase_timeout_when_expired() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        for phase in [
            KeTimeoutPhase::DnsSaturation,
            KeTimeoutPhase::DnsTimeout,
            KeTimeoutPhase::Connect,
            KeTimeoutPhase::Tls,
            KeTimeoutPhase::KeRecordIo,
        ] {
            let d = Deadline::new(Duration::from_micros(1));
            std::thread::sleep(Duration::from_millis(10));
            let tcp = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
            match d.apply_to_with_phase(&tcp, phase) {
                Err(KeError::PhaseTimeout(got)) => assert_eq!(got, phase),
                other => panic!(
                    "expired apply_to_with_phase({phase:?}) yielded {other:?}; \
                     expected KeError::PhaseTimeout({phase:?})",
                ),
            }
        }
    }

    /// Non-expired companion to the test above: when budget remains,
    /// `apply_to_with_phase` must shrink the socket's read+write
    /// timeouts to a strictly-positive value bounded above by the
    /// configured budget. Same shape as
    /// `deadline_apply_to_sets_socket_timeouts_within_remaining_budget`
    /// but exercising the phase-aware entry point.
    #[test]
    fn deadline_apply_to_with_phase_sets_socket_timeouts_within_remaining() {
        let budget = Duration::from_millis(500);
        let d = Deadline::new(budget);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let tcp = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        d.apply_to_with_phase(&tcp, KeTimeoutPhase::Tls)
            .expect("non-zero remaining");
        let read_t = tcp.read_timeout().unwrap().expect("read timeout set");
        let write_t = tcp.write_timeout().unwrap().expect("write timeout set");
        assert!(
            read_t > Duration::ZERO && read_t <= budget,
            "read timeout {read_t:?} must be in (0, {budget:?}]",
        );
        assert!(
            write_t > Duration::ZERO && write_t <= budget,
            "write timeout {write_t:?} must be in (0, {budget:?}]",
        );
    }

    /// `check_or_timeout` is the funnel `connect_with_deadline_using`
    /// consults before each blocking step. An expired budget must
    /// short-circuit with the supplied phase tag; a live budget must
    /// hand back the remaining slack so the caller can pass it to
    /// `connect_timeout` / `resolve_with_global` unchanged.
    #[test]
    fn deadline_check_or_timeout_short_circuits_after_expiry() {
        let d = Deadline::new(Duration::from_micros(1));
        std::thread::sleep(Duration::from_millis(10));
        match d.check_or_timeout(KeTimeoutPhase::DnsTimeout) {
            Err(KeError::PhaseTimeout(KeTimeoutPhase::DnsTimeout)) => {}
            other => panic!(
                "expired check_or_timeout yielded {other:?}; \
                 expected KeError::PhaseTimeout(DnsTimeout)",
            ),
        }

        let live = Deadline::new(Duration::from_millis(500));
        let remaining = live
            .check_or_timeout(KeTimeoutPhase::Connect)
            .expect("non-zero remaining");
        assert!(
            remaining > Duration::ZERO && remaining <= Duration::from_millis(500),
            "live check_or_timeout returned {remaining:?}; \
             expected (0, 500ms]",
        );
    }
}

mod error_translation {
    use super::*;

    /// Pins the three branches of `dns_error_to_ke`. The
    /// bounded-DNS resolver surfaces three distinct `io::Error`
    /// kinds and each must route to a distinct `KeError` shape so
    /// the `From<KeError> for NtsError` mapping in `api/nts.rs`
    /// preserves the difference between pool saturation, deadline
    /// expiry, and a real lookup failure.
    #[test]
    fn dns_error_to_ke_translates_each_io_kind() {
        match dns_error_to_ke(std::io::Error::from(std::io::ErrorKind::WouldBlock)) {
            KeError::PhaseTimeout(KeTimeoutPhase::DnsSaturation) => {}
            other => panic!("WouldBlock -> {other:?}; expected DnsSaturation"),
        }
        match dns_error_to_ke(std::io::Error::from(std::io::ErrorKind::TimedOut)) {
            KeError::PhaseTimeout(KeTimeoutPhase::DnsTimeout) => {}
            other => panic!("TimedOut -> {other:?}; expected DnsTimeout"),
        }
        let raw = std::io::Error::new(std::io::ErrorKind::AddrNotAvailable, "nxdomain");
        match dns_error_to_ke(raw) {
            KeError::Io(e) => assert!(
                e.to_string().contains("nxdomain"),
                "Io passthrough lost diagnostic: {e}",
            ),
            other => panic!("AddrNotAvailable -> {other:?}; expected KeError::Io"),
        }
    }

    /// Companion to `dns_error_to_ke_translates_each_io_kind` for the
    /// per-address connect leg. `TimedOut` is the only deadline
    /// signal `TcpStream::connect_timeout` raises; non-timeout
    /// kinds (`ConnectionRefused`, `NetworkUnreachable`, …) must
    /// reach Dart as `NtsError::Network` with the diagnostic
    /// preserved.
    #[test]
    fn connect_error_to_ke_translates_io_kinds() {
        match connect_error_to_ke(std::io::Error::from(std::io::ErrorKind::TimedOut)) {
            KeError::PhaseTimeout(KeTimeoutPhase::Connect) => {}
            other => panic!("TimedOut -> {other:?}; expected Connect"),
        }
        let raw = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "ECONNREFUSED");
        match connect_error_to_ke(raw) {
            KeError::Io(e) => assert!(
                e.to_string().contains("ECONNREFUSED"),
                "Io passthrough lost diagnostic: {e}",
            ),
            other => panic!("ConnectionRefused -> {other:?}; expected KeError::Io"),
        }
    }

    /// Companion translator for the TLS / record I/O legs. A stalled
    /// rustls Stream surfaces `TimedOut`/`WouldBlock` from the
    /// underlying socket and must inherit the caller-supplied phase
    /// tag (`Tls` or `KeRecordIo`); other kinds stay as
    /// `KeError::Io` so a real I/O error doesn't get mislabelled as
    /// a budget exhaustion.
    #[test]
    fn phase_io_to_ke_translates_each_io_kind() {
        for phase in [KeTimeoutPhase::Tls, KeTimeoutPhase::KeRecordIo] {
            for kind in [std::io::ErrorKind::TimedOut, std::io::ErrorKind::WouldBlock] {
                let io = std::io::Error::from(kind);
                match phase_io_to_ke(io, phase) {
                    KeError::PhaseTimeout(got) => assert_eq!(got, phase),
                    other => panic!(
                        "{kind:?} for {phase:?} -> {other:?}; \
                         expected PhaseTimeout({phase:?})",
                    ),
                }
            }
            let raw = std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "eof");
            match phase_io_to_ke(raw, phase) {
                KeError::Io(e) => assert!(e.to_string().contains("eof")),
                other => panic!("UnexpectedEof for {phase:?} -> {other:?}; expected Io"),
            }
        }
    }

    /// `Display for KeError` is the string the public API surfaces
    /// when a non-timeout shape escapes via `KeProtocol(format!("{e}"))`.
    /// The `PhaseTimeout` arm must include the phase tag verbatim
    /// so a log line still distinguishes "budget elapsed during
    /// connect" from "budget elapsed during TLS handshake".
    #[test]
    fn ke_error_display_renders_phase_timeout_with_phase_tag() {
        for phase in [
            KeTimeoutPhase::DnsSaturation,
            KeTimeoutPhase::DnsTimeout,
            KeTimeoutPhase::Connect,
            KeTimeoutPhase::Tls,
            KeTimeoutPhase::KeRecordIo,
        ] {
            let rendered = format!("{}", KeError::PhaseTimeout(phase));
            let tag = format!("{phase:?}");
            assert!(
                rendered.contains(&tag),
                "Display for PhaseTimeout({phase:?}) was {rendered:?}; \
                 expected to contain {tag:?}",
            );
        }
    }

    /// `Display for KeError::TrustBackendUnavailable` must render as
    /// `"trust backend unavailable: {m}"` with no `(PlatformOnly mode)`
    /// prefix. The variant is shared between platform-verifier failures
    /// and custom-roots failures, so the prefix was inaccurate for the
    /// latter; `PlatformOnly`-specific context is now embedded inside
    /// the inner message by the two call sites in
    /// `build_tls_config_inner`. Pins the user-facing diagnostic
    /// contract for nts-o88.
    #[test]
    fn ke_error_display_trust_backend_unavailable_omits_platform_only_prefix() {
        let rendered = format!(
            "{}",
            KeError::TrustBackendUnavailable("inner message".to_string()),
        );
        assert_eq!(rendered, "trust backend unavailable: inner message");
        assert!(
            !rendered.contains("(PlatformOnly mode)"),
            "Display must not embed the legacy `(PlatformOnly mode)` \
             prefix; got {rendered:?}",
        );

        let with_tag = format!(
            "{}",
            KeError::TrustBackendUnavailable("PlatformOnly mode: boom".to_string()),
        );
        assert_eq!(
            with_tag,
            "trust backend unavailable: PlatformOnly mode: boom",
        );
    }

    /// `platform_only_unavailable` must embed the `"PlatformOnly mode: "`
    /// tag inside the inner message so the variant's `Display` surfaces it
    /// verbatim. Calling the helper directly gives the `PlatformOnly` error
    /// path a unit-testable entry point that does not require triggering a
    /// real platform-verifier failure on CI.
    #[test]
    fn platform_only_unavailable_embeds_tag_and_inner_error() {
        let err = platform_only_unavailable("synthetic verifier error");
        let rendered = format!("{err}");
        assert!(
            rendered.contains("PlatformOnly mode:"),
            "expected `PlatformOnly mode:` tag in rendered error; got {rendered:?}",
        );
        assert!(
            rendered.contains("synthetic verifier error"),
            "expected inner error text in rendered error; got {rendered:?}",
        );
        // Confirm the variant identity is correct.
        assert!(
            matches!(err, KeError::TrustBackendUnavailable(_)),
            "expected TrustBackendUnavailable variant; got {err:?}",
        );
    }
}

mod live_integration {
    use super::*;

    /// Live integration probe against Cloudflare's public NTS-KE endpoint.
    ///
    /// Gated behind `--ignored` so the standard CI run never depends on the
    /// public network. Run manually with:
    ///   cargo test -p nts_rust nts::ke::tests::live_integration::ke_live_cloudflare \
    ///     -- --ignored --nocapture
    #[test]
    #[ignore = "requires outbound TCP/4460 to time.cloudflare.com"]
    fn ke_live_cloudflare() {
        let req = KeRequest {
            host: "time.cloudflare.com".to_owned(),
            port: 4460,
            aead_algorithms: vec![aead::AES_SIV_CMAC_256],
            timeout: Some(Duration::from_secs(10)),
            dns_concurrency_cap: crate::nts::dns::DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS,
            trust_mode: KeTrustMode::PlatformWithFallback,
            verification_time_override: None,
        };
        let outcome = perform_handshake(&req).expect("handshake");
        assert_eq!(outcome.aead_id, aead::AES_SIV_CMAC_256);
        assert_eq!(outcome.c2s_key.len(), 32);
        assert_eq!(outcome.s2c_key.len(), 32);
        assert_ne!(outcome.c2s_key, outcome.s2c_key);
        assert!(
            outcome.cookies.len() >= 8,
            "expected ≥8 cookies, got {}",
            outcome.cookies.len()
        );
        assert!(outcome.ntpv4_port > 0);
    }
}

mod streaming_read {
    use super::*;

    /// Pins the streaming-budget invariant: the per-handshake read
    /// accumulator cap [`NTS_KE_READ_BUDGET`] must be strictly less
    /// than the codec ceiling
    /// [`crate::nts::records::MAX_MESSAGE_BYTES`], so the streaming
    /// layer in [`read_to_end_capped`] rejects oversized responses
    /// before [`super::records::parse_message`] ever sees them. A
    /// future edit that lifts the streaming budget at or above the
    /// codec ceiling would silently re-expose the memory-pressure
    /// vector this cap exists to close (a malicious server forcing
    /// 64 KiB per failed handshake), so pin the relationship in a
    /// regression guard.
    #[test]
    fn nts_ke_read_budget_is_strictly_below_codec_ceiling() {
        let codec_ceiling = crate::nts::records::MAX_MESSAGE_BYTES;
        assert!(
            NTS_KE_READ_BUDGET < codec_ceiling,
            "streaming budget {NTS_KE_READ_BUDGET} must be strictly less than \
             codec ceiling {codec_ceiling}",
        );
    }

    /// Pins the cap-decision helper [`next_chunk_within_budget`]: an
    /// exact-fit append (the boundary case where the next read takes
    /// the accumulator to exactly `cap`) must succeed; a one-byte
    /// overshoot must trip [`KeError::ResponseTooLarge`] with the
    /// would-be post-append length surfaced as `received` so an
    /// operator inspecting the diagnostic can tell how far over the
    /// budget the offending read pushed the accumulator. The boundary
    /// is asserted explicitly because off-by-one errors in cap checks
    /// (`>` vs `>=`) are the canonical way these guards drift on
    /// edits, and the codec layer's analogous cap is `>` not `>=`.
    #[test]
    fn next_chunk_within_budget_accepts_exact_fit_and_rejects_overshoot() {
        next_chunk_within_budget(0, NTS_KE_READ_BUDGET, NTS_KE_READ_BUDGET)
            .expect("exact-fit (n == cap on empty buffer) must be accepted");
        next_chunk_within_budget(NTS_KE_READ_BUDGET - 1, 1, NTS_KE_READ_BUDGET)
            .expect("exact-fit (buf_len + n == cap) must be accepted");
        match next_chunk_within_budget(NTS_KE_READ_BUDGET, 1, NTS_KE_READ_BUDGET) {
            Err(KeError::ResponseTooLarge { received, cap }) => {
                assert_eq!(cap, NTS_KE_READ_BUDGET);
                assert_eq!(received, NTS_KE_READ_BUDGET + 1);
            }
            other => panic!("one-byte overshoot must yield ResponseTooLarge; got {other:?}",),
        }
    }

    /// Pins the cap-trip behaviour the bd-tracker entry calls out: a
    /// server (real or faux) that streams more than [`NTS_KE_READ_BUDGET`]
    /// bytes per handshake must be rejected mid-stream, before the
    /// accumulator grows past the budget, with the overshoot length
    /// surfaced in the diagnostic. Drives the cap-decision helper
    /// over a 100 KB body in 4 KiB chunks (matching the chunk size in
    /// [`read_to_end_capped`]) so the assertion exercises the same
    /// stride pattern the streaming loop uses, and pins both the
    /// trip-point (the chunk that crosses the budget) and the early-
    /// return semantics (no further chunks consumed once the cap is
    /// tripped).
    #[test]
    fn next_chunk_within_budget_trips_mid_stream_for_oversized_body() {
        const BODY_SIZE: usize = 100_000;
        const CHUNK_SIZE: usize = 4096;
        let mut received = 0usize;
        let mut tripped_at: Option<(usize, usize)> = None;
        for _ in 0..(BODY_SIZE.div_ceil(CHUNK_SIZE)) {
            let n = CHUNK_SIZE.min(BODY_SIZE - received);
            match next_chunk_within_budget(received, n, NTS_KE_READ_BUDGET) {
                Ok(()) => received += n,
                Err(KeError::ResponseTooLarge {
                    received: r,
                    cap: c,
                }) => {
                    tripped_at = Some((r, c));
                    break;
                }
                Err(other) => {
                    panic!("expected ResponseTooLarge or Ok, got {other:?} after {received} bytes",)
                }
            }
        }
        let (overshoot, cap) = tripped_at
            .expect("100 KB body must trip the 16 KiB streaming budget before the loop exits");
        assert_eq!(cap, NTS_KE_READ_BUDGET);
        assert!(
            overshoot > NTS_KE_READ_BUDGET,
            "overshoot {overshoot} must exceed cap {cap}",
        );
        assert!(
            received <= NTS_KE_READ_BUDGET,
            "accumulator {received} must not have grown past cap {cap} before the trip",
        );
    }
}

mod alpn_verification {
    use super::*;

    /// Pins the post-handshake ALPN check (RFC 8915 §4): when the
    /// server selects the `ntske/1` protocol identifier we advertised
    /// in `alpn_protocols`, [`check_negotiated_alpn`] must accept.
    /// Mirrors `next_chunk_within_budget`'s testing strategy: factor
    /// the decision out of the I/O-bound caller so a unit test can
    /// exercise the guard without standing up a TLS handshake.
    #[test]
    fn check_negotiated_alpn_accepts_ntske_one() {
        check_negotiated_alpn(Some(b"ntske/1")).expect("`ntske/1` selection must be accepted");
    }

    /// `rustls` raises `Error::NoApplicationProtocol` during the
    /// handshake when the server respects ALPN but has no protocol in
    /// common with our offer; this test pins the *other* shape — a
    /// server that completes the TLS handshake without advertising any
    /// ALPN extension at all. `check_negotiated_alpn(None)` must trip
    /// [`KeError::AlpnMismatch`] with `negotiated: None` so the
    /// diagnostic distinguishes "no ALPN at all" from "wrong ALPN".
    #[test]
    fn check_negotiated_alpn_rejects_missing_extension() {
        match check_negotiated_alpn(None) {
            Err(KeError::AlpnMismatch { negotiated: None }) => {}
            other => panic!("expected AlpnMismatch {{ negotiated: None }}, got {other:?}",),
        }
    }

    /// Pins the wrong-protocol shape: a server that completes the TLS
    /// handshake having selected an ALPN value other than `ntske/1`
    /// (e.g. `h2`, because the server treated our `[ntske/1]` offer
    /// as advisory and negotiated its own preferred protocol).
    /// `check_negotiated_alpn(Some(other))` must trip
    /// [`KeError::AlpnMismatch`] and surface the actual server
    /// selection in `negotiated` so an operator can attribute the
    /// failure without parsing free-form strings.
    #[test]
    fn check_negotiated_alpn_rejects_wrong_protocol() {
        match check_negotiated_alpn(Some(b"h2")) {
            Err(KeError::AlpnMismatch {
                negotiated: Some(bytes),
            }) => assert_eq!(
                bytes, b"h2",
                "negotiated payload must carry the server's actual selection verbatim",
            ),
            other => {
                panic!("expected AlpnMismatch {{ negotiated: Some(b\"h2\") }}, got {other:?}",)
            }
        }
    }

    /// Boundary case: empty ALPN payload. A misbehaving server could
    /// in principle complete the handshake having selected an empty
    /// byte string; the check must still reject (since the empty
    /// string is not `ntske/1`) and the diagnostic must carry the
    /// empty payload verbatim rather than collapsing onto the `None`
    /// arm — the two are different on-the-wire shapes (no extension
    /// vs extension carrying a zero-length protocol) and we want the
    /// surfaced error to preserve that distinction.
    #[test]
    fn check_negotiated_alpn_rejects_empty_payload_distinctly_from_missing() {
        match check_negotiated_alpn(Some(b"")) {
            Err(KeError::AlpnMismatch {
                negotiated: Some(bytes),
            }) => assert!(
                bytes.is_empty(),
                "empty-payload selection must survive as `Some(empty)`, not collapse to None",
            ),
            other => panic!("expected AlpnMismatch {{ negotiated: Some(empty) }}, got {other:?}",),
        }
    }
}

mod ke_outcome {
    use super::*;

    /// Compile-time pin that [`KeOutcome::c2s_key`] and
    /// [`KeOutcome::s2c_key`] are wrapped in [`zeroize::Zeroizing`].
    /// The wrapper's `Drop` impl wipes the underlying `Vec<u8>`
    /// allocation when the outcome is dropped, so the raw exporter
    /// material does not linger in freed heap pages until the next
    /// allocator overwrite.
    ///
    /// The function-signature trick (`assert_zeroizing_vec` accepts
    /// only `&Zeroizing<Vec<u8>>`) makes the test fail at compile
    /// time if either field is reverted to a bare `Vec<u8>`. The
    /// runtime construction is just enough to produce a value whose
    /// references can be passed to the assertion helper; nothing
    /// downstream of the field types is being asserted.
    #[test]
    fn ke_outcome_exporter_keys_are_zeroizing_wrapped() {
        fn assert_zeroizing_vec(_: &Zeroizing<Vec<u8>>) {}
        let outcome = KeOutcome {
            ntpv4_host: String::new(),
            ntpv4_port: 0,
            aead_id: 0,
            c2s_key: Zeroizing::new(vec![0u8; 1]),
            s2c_key: Zeroizing::new(vec![0u8; 1]),
            cookies: Vec::new(),
            warnings: Vec::new(),
            phase_timings: KePhaseTimings {
                dns_micros: 0,
                connect_micros: 0,
                tls_handshake_micros: 0,
                ke_record_io_micros: 0,
            },
            trust_backend: KeTrustBackend::Platform,
        };
        assert_zeroizing_vec(&outcome.c2s_key);
        assert_zeroizing_vec(&outcome.s2c_key);
    }

    /// Pins the manual `Debug` redaction on [`KeOutcome`]: every
    /// field carrying authentication material (`c2s_key`, `s2c_key`,
    /// `cookies`) must not appear in the rendered output, even
    /// though `Zeroizing<Vec<u8>>` derives `Debug` from the inner
    /// `Vec<u8>` and `Vec<Vec<u8>>` (the cookies field) would
    /// otherwise emit them verbatim. A regression that reverted to
    /// `#[derive(Debug)]` on `KeOutcome` would re-expose live key
    /// material *and* live cookies in any `{:?}` formatting site
    /// (assertion-failure messages, panic payloads, accidental log
    /// lines).
    ///
    /// The assertion shape has four legs:
    ///
    /// 1. The redaction marker `<redacted` appears exactly three
    ///    times — once per redacted field. Asserting the count
    ///    (rather than `>= 1`) catches a regression that drops the
    ///    redaction on one field while leaving it on the others.
    /// 2. The literal `0x55` / `0x77` / `0x99` byte patterns used
    ///    in the test fixture do not appear as hex tokens in the
    ///    rendered output. The fixtures use single-byte-value-
    ///    repeated buffers so the assertion can scan for `0x55` /
    ///    `0x77` / `0x99` (the form `{:?}` on `Vec<u8>` emits) and
    ///    not collide with hex digits that happen to appear inside
    ///    decimal field values like `aead_id: 15`.
    /// 3. The cookie *count* still appears (`3 cookies`), proving
    ///    the redacted form preserves the diagnostic length without
    ///    leaking the bytes themselves.
    /// 4. The non-secret host field still appears verbatim,
    ///    proving the manual impl didn't over-redact.
    #[test]
    fn ke_outcome_debug_redacts_exporter_keys_and_cookies() {
        let outcome = KeOutcome {
            ntpv4_host: "ntp.example.test".to_owned(),
            ntpv4_port: 4123,
            aead_id: 15,
            c2s_key: Zeroizing::new(vec![0x55u8; 32]),
            s2c_key: Zeroizing::new(vec![0x77u8; 32]),
            cookies: vec![Zeroizing::new(vec![0x99u8; 64]); 3],
            warnings: Vec::new(),
            phase_timings: KePhaseTimings {
                dns_micros: 0,
                connect_micros: 0,
                tls_handshake_micros: 0,
                ke_record_io_micros: 0,
            },
            trust_backend: KeTrustBackend::Platform,
        };
        let rendered = format!("{outcome:?}");
        assert_eq!(
            rendered.matches("<redacted").count(),
            3,
            "expected 3 redacted markers (c2s_key, s2c_key, cookies), got: {rendered}",
        );
        for hex_token in ["0x55", "0x77", "0x99"] {
            assert!(
                !rendered.contains(hex_token),
                "byte token {hex_token:?} from test fixture leaked into Debug output: {rendered}",
            );
        }
        assert!(
            rendered.contains("3 cookies"),
            "redacted cookies field must surface the count for diagnostics: {rendered}",
        );
        assert!(
            rendered.contains("ntp.example.test"),
            "non-secret host field must remain visible: {rendered}",
        );
    }
}

mod ke_outcome_partial {
    use super::*;

    /// Pins the manual `Debug` redaction on [`KeOutcomePartial`].
    /// Although the type is `pub(crate)` so its surface is
    /// internal, any `{:?}` site reached during a refactor (panic
    /// backtrace, `dbg!`, internal error formatting in a future
    /// `From<KeError>` chain) would leak the cookies a
    /// `#[derive(Debug)]` would emit verbatim. The cookies in this
    /// partial outcome are the same RFC 8915 §6 authentication
    /// material the post-handshake [`KeOutcome`] holds, so the
    /// redaction discipline matches: see the sibling
    /// `ke_outcome_debug_redacts_exporter_keys_and_cookies` test
    /// for the `KeOutcome` mirror.
    ///
    /// The runtime constructor stays inside the `ke` module so the
    /// `pub(crate)` `KeOutcomePartial` (and its private fields) are
    /// reachable from this test file. The sentinel cookie payload
    /// `0xBB` is chosen so the hex token `0xbb` that
    /// `Vec<u8>::Debug` would emit on a regression cannot collide
    /// with any decimal field rendering, making the negative
    /// assertion unambiguous.
    #[test]
    fn ke_outcome_partial_debug_redacts_cookies() {
        let partial = KeOutcomePartial {
            ntpv4_host: "ntp.example.test".to_owned(),
            ntpv4_port: 4123,
            aead_id: 15,
            cookies: vec![Zeroizing::new(vec![0xBBu8; 64]); 3],
            warnings: Vec::new(),
        };
        let rendered = format!("{partial:?}");
        assert_eq!(
            rendered.matches("<redacted").count(),
            1,
            "expected exactly one redacted marker (cookies): {rendered}",
        );
        assert!(
            !rendered.contains("0xbb"),
            "cookie byte token leaked into Debug output: {rendered}",
        );
        assert!(
            rendered.contains("3 cookies"),
            "redacted cookies field must surface the count for diagnostics: {rendered}",
        );
        assert!(
            rendered.contains("ntp.example.test"),
            "non-secret host field must remain visible: {rendered}",
        );
    }
}
