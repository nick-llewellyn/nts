use super::*;
use crate::nts::records::aead as aead_ids;

#[test]
fn validate_rejects_empty_host() {
    let err = validate(&NtsServerSpec {
        host: String::new(),
        port: 4460,
    })
    .unwrap_err();
    assert!(matches!(err, NtsError::InvalidSpec(_)), "got {err:?}");
}

#[test]
fn validate_rejects_zero_port() {
    let err = validate(&NtsServerSpec {
        host: "h".into(),
        port: 0,
    })
    .unwrap_err();
    assert!(matches!(err, NtsError::InvalidSpec(_)), "got {err:?}");
}

/// Pins the FFI-default behaviour for `dns_concurrency_cap`: a `0`
/// from Dart is the agreed sentinel for "use the built-in default",
/// matching `timeout_ms`. Regressing this would silently let a
/// pathological caller pass `0` and saturate the resolver pool
/// (since `try_acquire_slot` with `cap = 0` always rejects).
#[test]
fn effective_dns_concurrency_cap_substitutes_default_when_zero() {
    assert_eq!(
        effective_dns_concurrency_cap(0),
        DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS,
    );
    assert_eq!(effective_dns_concurrency_cap(1), 1);
    assert_eq!(effective_dns_concurrency_cap(32), 32);
}

#[test]
fn effective_timeout_substitutes_default_when_zero() {
    assert_eq!(
        effective_timeout(0),
        Duration::from_millis(DEFAULT_TIMEOUT_MS.into())
    );
    assert_eq!(effective_timeout(1234), Duration::from_millis(1234));
}

/// Pins the cross-layer contract between the Rust-side defaults
/// (`DEFAULT_TIMEOUT_MS` here, `DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS` in
/// `rust/src/nts/dns.rs`) and the Dart wrapper constants that expose
/// the same numeric values to consumers (`kDefaultTimeoutMs` and
/// `kDefaultDnsConcurrencyCap` in `lib/src/api/nts.dart`).
///
/// The Dart wrapper rejects `0` for either argument and steers
/// callers to pass `kDefault*` instead, so the Rust-side 0-as-default
/// sentinel handled by [`effective_timeout`] and
/// [`effective_dns_concurrency_cap`] is unreachable from Dart callers.
/// The two layers therefore agree on the effective value only as long
/// as the literal numerics agree. There is no compile-time link
/// between them (the Dart constants are not code-generated from the
/// Rust ones), so a change to either side that is not mirrored on the
/// other silently drifts the Dart-documented default away from the
/// Rust runtime default.
///
/// This test plus its companion in `test/api_smoke_test.dart`
/// (`'exported defaults expose the actual numeric values'`) catch
/// that drift on both sides: tightening one constant without updating
/// the other breaks the test on the changed side, forcing the
/// developer to consider the other layer before merging.
#[test]
fn defaults_match_dart_wrapper_constants() {
    assert_eq!(
        DEFAULT_TIMEOUT_MS, 5_000,
        "DEFAULT_TIMEOUT_MS must equal kDefaultTimeoutMs in lib/src/api/nts.dart; \
         update both sides in lockstep",
    );
    assert_eq!(
        DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS, 4,
        "DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS must equal kDefaultDnsConcurrencyCap in \
         lib/src/api/nts.dart; update both sides in lockstep",
    );
}

#[test]
fn ntp64_round_trips_through_micros() {
    // 2026-04-25T00:00:00Z = 1777334400 unix seconds = 3986323200 NTP seconds.
    let ntp = 3_986_323_200u64 << 32;
    assert_eq!(ntp64_to_unix_micros(ntp), 1_777_334_400 * 1_000_000);
}

#[test]
fn ntp64_decodes_subsecond_fraction() {
    // 0.5s after the NTP-epoch -> -2208988800.5 Unix seconds.
    let ntp = 1u64 << 31; // top bit of low 32 set => 0.5s frac, secs=0.
    let micros = ntp64_to_unix_micros(ntp);
    assert_eq!(
        micros,
        -(NTP_TO_UNIX_EPOCH_SECS as i64) * 1_000_000 + 500_000
    );
}

#[test]
fn unix_duration_round_trips_to_ntp64() {
    let d = Duration::new(1_777_334_400, 250_000_000); // 2026-04-25, 0.25s.
    let ntp = unix_duration_to_ntp64(d);
    let micros = ntp64_to_unix_micros(ntp);
    assert_eq!(micros, 1_777_334_400 * 1_000_000 + 250_000);
}

/// Bind a local IPv4 echo socket and verify `bind_connected_udp`
/// resolves `127.0.0.1`, picks a matching-family local socket, and
/// completes a round trip. This is the address-family-matching
/// regression guard for [`bind_connected_udp`] on the IPv4 leg.
#[test]
fn bind_connected_udp_handles_ipv4_loopback() {
    let echo = UdpSocket::bind("127.0.0.1:0").expect("bind echo");
    let echo_port = echo.local_addr().expect("local addr").port();

    // Generous cap so the suite's parallel slow-DNS tests
    // (which leak detached workers for ~2 s) cannot saturate the
    // global pool out from under this test. Pool-cap behaviour
    // itself is covered by `dns::tests::cap_reached_returns_would_block`.
    let UdpBindOutcome { socket, .. } =
        bind_connected_udp("127.0.0.1", echo_port, Duration::from_secs(2), 64)
            .expect("bind_connected_udp");
    assert!(matches!(
        socket.local_addr().expect("local addr"),
        SocketAddr::V4(_)
    ));
    socket.send(b"ping").expect("send");
    let mut buf = [0u8; 16];
    let (n, src) = echo.recv_from(&mut buf).expect("recv");
    assert_eq!(&buf[..n], b"ping");
    assert!(matches!(src, SocketAddr::V4(_)));
}

/// IPv6 loopback variant. Skipped at runtime if the host kernel has
/// no `::1` interface (e.g. some minimal CI images) — that's the
/// only legitimate reason to skip rather than fail. The whole point
/// of this fix is to support hosts like Netnod that publish only
/// AAAA records, and `::1` exercises the same code path.
#[test]
fn bind_connected_udp_handles_ipv6_loopback() {
    let echo = match UdpSocket::bind("[::1]:0") {
        Ok(s) => s,
        Err(e) => {
            eprintln!("skipping: host lacks IPv6 loopback support ({e})");
            return;
        }
    };
    let echo_port = echo.local_addr().expect("local addr").port();

    let UdpBindOutcome { socket, .. } =
        bind_connected_udp("::1", echo_port, Duration::from_secs(2), 64)
            .expect("bind_connected_udp");
    assert!(matches!(
        socket.local_addr().expect("local addr"),
        SocketAddr::V6(_)
    ));
    socket.send(b"ping6").expect("send");
    let mut buf = [0u8; 16];
    let (n, src) = echo.recv_from(&mut buf).expect("recv");
    assert_eq!(&buf[..n], b"ping6");
    assert!(matches!(src, SocketAddr::V6(_)));
}

/// Build a throwaway `Session` for cookie-jar plumbing tests.
///
/// Uses AES-SIV-CMAC-256 because it's the RFC 8915 §5.1 baseline
/// and `AeadKey::from_keying_material` will accept any 32-byte
/// blob — these tests never seal or open packets, they only
/// exercise the session-table bookkeeping around `deposit_cookies`.
fn make_test_session(host: &str, ntpv4_port: u16, generation: u64) -> Session {
    let key_material = [0u8; 32];
    let c2s_key = AeadKey::from_keying_material(aead_ids::AES_SIV_CMAC_256, &key_material)
        .expect("32-byte SIV key");
    let s2c_key = AeadKey::from_keying_material(aead_ids::AES_SIV_CMAC_256, &key_material)
        .expect("32-byte SIV key");
    Session {
        generation,
        aead_id: aead_ids::AES_SIV_CMAC_256,
        c2s_key,
        s2c_key,
        ntpv4_host: host.to_owned(),
        ntpv4_port,
        jar: CookieJar::new(),
        trust_backend: TrustBackend::Platform,
    }
}

/// Sanity check on the generation oracle: every call must return a
/// distinct value. If this ever regresses (e.g. someone swaps the
/// counter for a hash of the spec), the race-fix invariant in
/// `deposit_cookies` collapses silently.
#[test]
fn next_session_generation_is_unique() {
    let a = next_session_generation();
    let b = next_session_generation();
    let c = next_session_generation();
    assert_ne!(a, b);
    assert_ne!(b, c);
    assert_ne!(a, c);
}

/// Happy path: when the cached session's generation still matches the
/// `QueryContext`, fresh cookies land in the jar as before.
#[test]
fn deposit_cookies_writes_when_generation_matches() {
    let key = "deposit-match.invalid:4460";
    let gen = next_session_generation();
    let session = make_test_session("deposit-match.invalid", 123, gen);
    sessions()
        .lock()
        .expect("session table poisoned")
        .insert(key.to_owned(), session);

    deposit_cookies(key, gen, vec![vec![1, 2, 3], vec![4, 5, 6]]);

    let guard = sessions().lock().expect("session table poisoned");
    let s = guard.get(key).expect("session present");
    assert_eq!(
        s.cookies_remaining(),
        2,
        "expected both cookies to land in the matched session's jar"
    );
    // Drop the lock before we mutate the table again.
    drop(guard);
    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(key);
}

/// Race-fix invariant: when a concurrent handshake replaces the
/// cached session between checkout and deposit, the in-flight
/// query's cookies are bound to the old C2S/S2C keys and must be
/// discarded — depositing them into the new session would cause
/// every future query to fail authentication and trigger another
/// (wasted) re-handshake.
#[test]
fn deposit_cookies_drops_when_session_replaced() {
    let key = "deposit-mismatch.invalid:4460";
    // Stand up an "old" session and snapshot its generation as a
    // simulated `QueryContext.session_generation`. Generations come
    // from the real oracle so this test exercises the same
    // uniqueness guarantee `establish_session` relies on.
    let stale_generation = next_session_generation();
    let old = make_test_session("deposit-mismatch.invalid", 123, stale_generation);
    sessions()
        .lock()
        .expect("session table poisoned")
        .insert(key.to_owned(), old);

    // Simulate `nts_warm_cookies` (or another `checkout` re-handshake)
    // landing while the original query was on the wire: replace the
    // entry under the same key with a session whose generation has
    // advanced.
    let fresh_generation = next_session_generation();
    assert_ne!(
        stale_generation, fresh_generation,
        "fresh handshake must mint a distinct generation"
    );
    let fresh = make_test_session("deposit-mismatch.invalid", 123, fresh_generation);
    sessions()
        .lock()
        .expect("session table poisoned")
        .insert(key.to_owned(), fresh);

    // Deposit with the *stale* generation — must be a no-op.
    deposit_cookies(key, stale_generation, vec![vec![0xAA; 16]; 4]);

    let guard = sessions().lock().expect("session table poisoned");
    let s = guard.get(key).expect("session present");
    assert_eq!(
        s.cookies_remaining(),
        0,
        "stale-generation cookies must not poison the new session's jar",
    );
    assert_eq!(
        s.generation, fresh_generation,
        "fresh session must still be the one cached",
    );
    drop(guard);
    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(key);
}

/// If the session was evicted entirely (no entry at the key), a
/// late deposit is a quiet no-op rather than a panic. This was
/// already the behaviour pre-fix; the regression test pins it
/// explicitly so the new generation check can't accidentally
/// reintroduce a panic on the missing-entry path.
#[test]
fn deposit_cookies_is_noop_when_session_missing() {
    let key = "deposit-missing.invalid:4460";
    // Ensure no leftover from another test.
    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(key);
    // Any generation ID will do — the entry is absent.
    deposit_cookies(key, 1, vec![vec![1, 2, 3]]);
    // No assertion needed beyond "did not panic"; verify the table
    // really is empty for this key.
    let guard = sessions().lock().expect("session table poisoned");
    assert!(guard.get(key).is_none());
}

/// Happy path for the fail-fast eviction: when the cached session's
/// generation matches the in-flight query's snapshot, a tag-mismatch
/// failure removes the entry so the next `checkout` performs a
/// fresh KE handshake instead of draining the rest of the now-stale
/// cookie pool through identical authentication failures.
#[test]
fn evict_session_drops_entry_when_generation_matches() {
    let key = "evict-match.invalid:4460";
    let gen = next_session_generation();
    let mut session = make_test_session("evict-match.invalid", 123, gen);
    // Pre-seed the jar so we can assert the *whole* entry is gone,
    // not just its cookie queue.
    let host = session.ntpv4_host.clone();
    session
        .jar
        .put_many(&host, [vec![1u8; 16], vec![2; 16], vec![3; 16]]);
    sessions()
        .lock()
        .expect("session table poisoned")
        .insert(key.to_owned(), session);

    evict_session(key, gen);

    let guard = sessions().lock().expect("session table poisoned");
    assert!(
        guard.get(key).is_none(),
        "matching-generation eviction must drop the entry, jar and keys with it",
    );
}

/// Race-fix invariant: if a concurrent re-handshake replaced the
/// cached session between checkout and the failed exchange, the
/// in-flight failure belongs to the *old* keys; the freshly-rotated
/// session must survive. Without this guard a single transient
/// authentication error would force every concurrent caller for
/// the same host through a redundant re-handshake.
#[test]
fn evict_session_preserves_entry_on_generation_mismatch() {
    let key = "evict-mismatch.invalid:4460";
    let stale_generation = next_session_generation();
    // The in-flight query thinks it's still on this generation.
    sessions().lock().expect("session table poisoned").insert(
        key.to_owned(),
        make_test_session("evict-mismatch.invalid", 123, stale_generation),
    );
    // Concurrent re-handshake lands while the original query was on
    // the wire: replace the entry with one whose generation has
    // advanced.
    let fresh_generation = next_session_generation();
    assert_ne!(
        stale_generation, fresh_generation,
        "generation oracle must hand out distinct values",
    );
    sessions().lock().expect("session table poisoned").insert(
        key.to_owned(),
        make_test_session("evict-mismatch.invalid", 123, fresh_generation),
    );

    // The stale-generation eviction must be a no-op.
    evict_session(key, stale_generation);

    let guard = sessions().lock().expect("session table poisoned");
    let s = guard.get(key).expect("fresh session must survive");
    assert_eq!(
        s.generation, fresh_generation,
        "stale-generation eviction must not drop the freshly-rotated session",
    );
    drop(guard);
    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(key);
}

/// A late eviction against an already-evicted (or never-installed)
/// entry is a quiet no-op rather than a panic. Companion to the
/// `deposit_cookies_is_noop_when_session_missing` regression guard;
/// pins the same property for the symmetric eviction path.
#[test]
fn evict_session_is_noop_when_session_missing() {
    let key = "evict-missing.invalid:4460";
    // Ensure no leftover from another test.
    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(key);
    // Any generation ID will do — the entry is absent.
    evict_session(key, 1);
    let guard = sessions().lock().expect("session table poisoned");
    assert!(guard.get(key).is_none());
}

/// End-to-end coverage for `nts_query`'s fail-fast eviction on
/// AEAD authentication failure. Pre-installs a session pointing
/// at a loopback faux server, then has the faux server reply
/// with the client's own packet but with the LI/VN/Mode byte
/// flipped from CLIENT (3) to SERVER (4). The mode check
/// passes, but the AEAD-sealed AAD covers the *original* byte,
/// so `s2c_key.open_packet` fails on a tag mismatch — surfaced
/// as `NtsError::Authentication` and routed through
/// `evict_on_rekey_signal`. The cached entry must be gone after the
/// call returns so the caller's next `checkout` performs a
/// fresh KE handshake instead of draining the rest of the
/// now-stale cookie pool through identical failures and the
/// per-source exponential backoff that produces the multi-hour
/// recovery stall downstream consumers observed.
#[test]
fn nts_query_evicts_session_on_aead_authentication_failure() {
    let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
    faux_server
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("set faux server read timeout");
    let server_port = faux_server.local_addr().expect("local addr").port();
    let host = "127.0.0.1";
    let key = format!("{host}:{server_port}");

    // Defensive cleanup in case a prior test crashed mid-run.
    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(&key);

    // Pre-install a session with a single cookie so `checkout`
    // does not trigger a real KE handshake. The AEAD keys are
    // valid (any 32 bytes is accepted by AES-SIV-CMAC-256), so
    // `build_client_request` produces a real authenticated
    // packet that the faux server can mutate.
    let generation = next_session_generation();
    let mut session = make_test_session(host, server_port, generation);
    session.jar.put_many(host, [vec![0xAB; 32]]);
    sessions()
        .lock()
        .expect("session table poisoned")
        .insert(key.clone(), session);

    let handler = std::thread::spawn(move || {
        let mut buf = [0u8; 2048];
        let (n, src) = faux_server
            .recv_from(&mut buf)
            .expect("faux server recv_from");
        // Flip mode bits in the LI/VN/Mode byte: CLIENT (3) ->
        // SERVER (4). The AEAD-sealed AAD covers the original
        // byte, so the client's S2C open will fail on a tag
        // mismatch — same shape as a real server-side master
        // key rotation.
        buf[0] = (buf[0] & !0b0000_0111) | 0b0000_0100;
        faux_server
            .send_to(&buf[..n], src)
            .expect("faux server send_to");
    });

    let spec = NtsServerSpec {
        host: host.to_owned(),
        port: server_port,
    };
    let result = nts_query(spec, 2_000, 64);
    handler.join().expect("faux server thread panicked");

    match result {
        Err(NtsError::Authentication { .. }) => {}
        other => panic!("expected NtsError::Authentication, got {other:?}"),
    }

    let guard = sessions().lock().expect("session table poisoned");
    assert!(
        guard.get(&key).is_none(),
        "fail-fast eviction must remove the session entry on AEAD authentication failure",
    );
}

/// Companion to the AEAD-eviction test: a non-AEAD protocol
/// failure (server reply still in CLIENT mode, caught by
/// `UnexpectedMode` before AEAD verify even runs) surfaces as
/// `NtsError::NtpProtocol` and must NOT evict the session. The
/// cached keys are still in sync with whatever the server
/// holds, and a redundant re-handshake on every transient
/// wire-shape glitch would defeat the whole point of the
/// cookie pool.
#[test]
fn nts_query_preserves_session_on_non_authentication_failure() {
    let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
    faux_server
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("set faux server read timeout");
    let server_port = faux_server.local_addr().expect("local addr").port();
    let host = "127.0.0.1";
    let key = format!("{host}:{server_port}");

    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(&key);

    let generation = next_session_generation();
    let mut session = make_test_session(host, server_port, generation);
    session.jar.put_many(host, [vec![0xCD; 32]]);
    sessions()
        .lock()
        .expect("session table poisoned")
        .insert(key.clone(), session);

    let handler = std::thread::spawn(move || {
        let mut buf = [0u8; 2048];
        let (n, src) = faux_server
            .recv_from(&mut buf)
            .expect("faux server recv_from");
        // Echo the request back unmodified — mode is still
        // CLIENT (3), which `parse_server_response` rejects
        // with `UnexpectedMode` before reaching AEAD verify.
        // Maps to `NtsError::NtpProtocol`.
        faux_server
            .send_to(&buf[..n], src)
            .expect("faux server send_to");
    });

    let spec = NtsServerSpec {
        host: host.to_owned(),
        port: server_port,
    };
    let result = nts_query(spec, 2_000, 64);
    handler.join().expect("faux server thread panicked");

    match result {
        Err(NtsError::NtpProtocol { .. }) => {}
        other => panic!("expected NtsError::NtpProtocol, got {other:?}"),
    }

    let guard = sessions().lock().expect("session table poisoned");
    assert!(
        guard.get(&key).is_some(),
        "non-authentication failures must leave the cached session intact",
    );
    assert_eq!(
        guard.get(&key).expect("entry present").generation,
        generation,
        "preserved session must still be the same generation",
    );
    drop(guard);

    // Cleanup so this test does not leak global state to others.
    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(&key);
}

/// End-to-end coverage for `nts_query`'s eviction on a
/// standards-compliant RFC 8915 §5.7 NTSN Kiss-of-Death response.
/// Pre-installs a session pointing at a loopback faux server, then
/// has the faux server reply with a stratum-0 / `reference_id`=NTSN
/// packet that echoes the request's Unique Identifier and contains
/// no Authenticator (the shape a real server sends when its master
/// key has rotated and the cookie can no longer be unwrapped).
///
/// The previous AEAD-only eviction path missed this shape entirely:
/// `parse_server_response` rejected it as `MissingAuthenticator`
/// (mapped to `NtsError::NtpProtocol`) so the cached session
/// survived and the caller would keep draining identical failures
/// through the cookie pool. The new `NtpError::StaleCookie` arm
/// surfaces the matching-UID NTSN distinctly and routes it through
/// the same generation-guarded eviction as the AEAD path.
#[test]
fn nts_query_evicts_session_on_ntsn_kod_with_matching_uid() {
    use crate::nts::ntp::{
        ext_type, mode, parse_extensions, NtpHeader, HEADER_LEN, STRATUM_KISS_OF_DEATH, VERSION_4,
    };

    let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
    faux_server
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("set faux server read timeout");
    let server_port = faux_server.local_addr().expect("local addr").port();
    let host = "127.0.0.1";
    let key = format!("{host}:{server_port}");

    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(&key);

    let generation = next_session_generation();
    let mut session = make_test_session(host, server_port, generation);
    session.jar.put_many(host, [vec![0xEF; 32]]);
    sessions()
        .lock()
        .expect("session table poisoned")
        .insert(key.clone(), session);

    let handler = std::thread::spawn(move || {
        let mut buf = [0u8; 2048];
        let (n, src) = faux_server
            .recv_from(&mut buf)
            .expect("faux server recv_from");
        // Recover the client's Unique Identifier so the reply can
        // echo it (RFC 8915 §5.7's MUST). Any other UID would be
        // treated as untrustworthy by the parser and fall through
        // to MissingAuthenticator instead of StaleCookie.
        let exts = parse_extensions(&buf[HEADER_LEN..n]).expect("parse client extensions");
        let client_uid = exts
            .iter()
            .find(|ext| ext.field_type == ext_type::UNIQUE_IDENTIFIER)
            .expect("client request must include a Unique Identifier")
            .body
            .clone();

        // Build a wire-correct §5.7 NAK: stratum 0 + ref_id NTSN +
        // server mode + echoed UID, no Authenticator and no
        // Encrypted Extension Fields.
        let mut header = NtpHeader::client_request(0);
        header.li_vn_mode = (VERSION_4 << 3) | mode::SERVER;
        header.stratum = STRATUM_KISS_OF_DEATH;
        header.reference_id = *b"NTSN";
        let mut reply = header.to_bytes().to_vec();
        reply.extend_from_slice(&crate::nts::ntp::encode_extension(
            ext_type::UNIQUE_IDENTIFIER,
            &client_uid,
        ));
        faux_server
            .send_to(&reply, src)
            .expect("faux server send_to");
    });

    let spec = NtsServerSpec {
        host: host.to_owned(),
        port: server_port,
    };
    let result = nts_query(spec, 2_000, 64);
    handler.join().expect("faux server thread panicked");

    // The unauthenticated NTSN routes through `From<NtpError>` to
    // `NtpProtocol` for the Dart-facing diagnostic, but eviction
    // already fired pre-conversion inside `evict_on_rekey_signal`.
    match result {
        Err(NtsError::NtpProtocol { message: msg, .. }) if msg.contains("NTSN") => {}
        other => panic!("expected NtpProtocol(StaleCookie) for NTSN reply, got {other:?}"),
    }

    let guard = sessions().lock().expect("session table poisoned");
    assert!(
        guard.get(&key).is_none(),
        "RFC 8915 §5.7 NTSN with matching UID must evict the cached session",
    );
}

/// Off-path-attacker guard at the integration layer: an
/// NTSN-shaped reply that does NOT echo the request's Unique
/// Identifier carries no trust signal and must NOT evict the
/// session. Pinning this here (not just in the parser unit
/// tests) guarantees the integration path also refuses to act
/// on a UID-mismatched NAK.
#[test]
fn nts_query_preserves_session_on_ntsn_kod_with_wrong_uid() {
    use crate::nts::ntp::{ext_type, mode, NtpHeader, STRATUM_KISS_OF_DEATH, VERSION_4};

    let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
    faux_server
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("set faux server read timeout");
    let server_port = faux_server.local_addr().expect("local addr").port();
    let host = "127.0.0.1";
    let key = format!("{host}:{server_port}");

    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(&key);

    let generation = next_session_generation();
    let mut session = make_test_session(host, server_port, generation);
    session.jar.put_many(host, [vec![0x12; 32]]);
    sessions()
        .lock()
        .expect("session table poisoned")
        .insert(key.clone(), session);

    let handler = std::thread::spawn(move || {
        let mut buf = [0u8; 2048];
        let (_n, src) = faux_server
            .recv_from(&mut buf)
            .expect("faux server recv_from");
        // Build an NTSN reply with a *different* UID — the shape
        // an off-path attacker would forge if they could send to
        // our ephemeral source port without observing our request.
        let mut header = NtpHeader::client_request(0);
        header.li_vn_mode = (VERSION_4 << 3) | mode::SERVER;
        header.stratum = STRATUM_KISS_OF_DEATH;
        header.reference_id = *b"NTSN";
        let mut reply = header.to_bytes().to_vec();
        let attacker_uid = [0xA5u8; 32];
        reply.extend_from_slice(&crate::nts::ntp::encode_extension(
            ext_type::UNIQUE_IDENTIFIER,
            &attacker_uid,
        ));
        faux_server
            .send_to(&reply, src)
            .expect("faux server send_to");
    });

    let spec = NtsServerSpec {
        host: host.to_owned(),
        port: server_port,
    };
    let result = nts_query(spec, 2_000, 64);
    handler.join().expect("faux server thread panicked");

    // Wrong-UID NTSN falls through to `MissingAuthenticator` in
    // the parser, which maps to `NtpProtocol` and bypasses the
    // eviction match arm.
    match result {
        Err(NtsError::NtpProtocol { .. }) => {}
        other => panic!("expected NtpProtocol for wrong-UID NTSN, got {other:?}"),
    }

    let guard = sessions().lock().expect("session table poisoned");
    assert!(
        guard.get(&key).is_some(),
        "wrong-UID NTSN must not evict (no authenticity signal)",
    );
    assert_eq!(
        guard.get(&key).expect("entry present").generation,
        generation,
        "preserved session must still be the same generation",
    );
    drop(guard);
    sessions()
        .lock()
        .expect("session table poisoned")
        .remove(&key);
}

/// A hostname that resolves to nothing maps to a structured
/// `NtsError::Network` rather than panicking. We use the
/// `.invalid` reserved TLD (RFC 6761 §6.4) so the test never
/// hits a real DNS responder.
#[test]
fn bind_connected_udp_reports_dns_failure() {
    let err = bind_connected_udp("no-such-host.invalid", 123, Duration::from_millis(500), 64)
        .expect_err("must fail");
    match err {
        NtsError::Network { message: msg, .. } => {
            assert!(
                msg.contains("no-such-host.invalid"),
                "expected hostname in error, got {msg}",
            );
        }
        other => panic!("expected NtsError::Network, got {other:?}"),
    }
}

/// Slow-DNS regression guard for [`bind_connected_udp`]. Injects a
/// resolver that blocks past the budget and asserts the call
/// returns `NtsError::Timeout { phase: TimeoutPhase::DnsTimeout, trust_backend: None }` (not
/// `NtsError::Network`) well inside the cap. Pinning the phase
/// tag here is what consumers of the post-`nts-r2l` API rely on
/// to attribute the failure to a stalled `getaddrinfo` rather
/// than to a downstream NTP or KE step. Companion to
/// `dns::tests::slow_resolver_*` and
/// `nts::ke::tests::connect_with_timeout_surfaces_slow_dns_*`; see
/// `nts-6ka` for the full set of injection points.
#[test]
fn bind_connected_udp_surfaces_slow_dns_as_timeout() {
    let budget = Duration::from_millis(50);
    let started = Instant::now();
    let result = bind_connected_udp_using("ignored.invalid", 0, budget, 64, |_host, _port| {
        std::thread::sleep(Duration::from_secs(2));
        Ok(vec![SocketAddr::from(([127, 0, 0, 1], 0))])
    });
    let elapsed = started.elapsed();

    match result {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::DnsTimeout,
            trust_backend: None,
        }) => {}
        other => panic!("slow-DNS path must surface as Timeout(DnsTimeout), got {other:?}",),
    }
    let cap = budget * 5;
    assert!(
        elapsed < cap,
        "bind_connected_udp took {elapsed:?} (> {cap:?}); \
         resolver budget did not propagate",
    );
}

/// Pins the `UdpDeadline::remaining_or_timeout` contract: once the
/// anchored instant has passed, the helper short-circuits with
/// `NtsError::Timeout(_)` rather than handing back a zero-length
/// `Duration` (which the platform would reject when fed to
/// `set_read_timeout`). The connect/bind path in
/// `bind_connected_udp_using` relies on this to surface budget
/// exhaustion as a phase-tagged `Timeout` instead of
/// `NtsError::Network`.
#[test]
fn udp_deadline_remaining_or_timeout_after_expiry() {
    let d = UdpDeadline::new(Duration::from_micros(1));
    std::thread::sleep(Duration::from_millis(10));
    assert!(d.remaining().is_zero(), "expired deadline must saturate");
    match d.remaining_or_timeout(TimeoutPhase::Ntp) {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::Ntp,
            trust_backend: None,
        }) => {}
        other => panic!("expired deadline must yield Timeout(Ntp), got {other:?}"),
    }
}

/// Drives `bind_connected_udp_using` against a 127.0.0.1 echo
/// socket but injects a resolver that consumes the bulk of the
/// budget before returning. The post-bind `set_read_timeout` /
/// `set_write_timeout` calls must see the *remaining* budget, not
/// the caller's original `timeout`. We pin both bounds on the
/// resulting socket: strictly less than the original budget (the
/// regression this test guards against would re-arm the full
/// duration) and strictly positive (a zero-length deadline would
/// short-circuit before bind). Companion to nts-zf2.
#[test]
fn bind_connected_udp_socket_timeouts_reflect_remaining_budget() {
    let echo = UdpSocket::bind("127.0.0.1:0").expect("bind echo");
    let echo_addr = echo.local_addr().expect("local addr");
    let echo_port = echo_addr.port();

    let budget = Duration::from_millis(500);
    let dns_consumes = Duration::from_millis(200);
    let UdpBindOutcome { socket, .. } = bind_connected_udp_using(
        "ignored.invalid",
        echo_port,
        budget,
        64,
        move |_host, _port| {
            std::thread::sleep(dns_consumes);
            Ok(vec![SocketAddr::from(([127, 0, 0, 1], echo_port))])
        },
    )
    .expect("bind_connected_udp_using");

    let read_t = socket
        .read_timeout()
        .expect("read_timeout call ok")
        .expect("read timeout set");
    let write_t = socket
        .write_timeout()
        .expect("write_timeout call ok")
        .expect("write timeout set");

    // The original `timeout` was 500 ms and the resolver burned
    // 200 ms of it; the post-bind socket timeouts must therefore
    // be strictly less than 500 ms (and not zero). Allow
    // generous slack on the upper bound so this test is robust
    // to scheduling jitter on slow CI runners while still
    // catching the regression — re-arming the full `timeout`
    // would land the socket timeout at exactly 500 ms.
    #[expect(
        clippy::unchecked_time_subtraction,
        reason = "test-local: `budget` is the locally-constructed 500 ms \
                  timeout from the prior assertion block, well above the \
                  50 ms slack subtrahend; underflow is impossible by \
                  construction"
    )]
    let upper_bound = budget - Duration::from_millis(50);
    assert!(
        read_t > Duration::ZERO && read_t < upper_bound,
        "read_timeout {read_t:?} must be in (0, {upper_bound:?}); \
         original budget was {budget:?} and DNS consumed ~{dns_consumes:?}",
    );
    assert!(
        write_t > Duration::ZERO && write_t < upper_bound,
        "write_timeout {write_t:?} must be in (0, {upper_bound:?}); \
         original budget was {budget:?} and DNS consumed ~{dns_consumes:?}",
    );
}

/// Companion to `bind_connected_udp_socket_timeouts_reflect_remaining_budget`
/// for the post-bind portion of `nts_query`. The UDP socket
/// emerges from `bind_connected_udp` with a read timeout sized to
/// the budget remaining at *bind* completion; without re-arming
/// before recv, a slow `send` or scheduling delay between bind
/// and recv would let recv block for that full bind-time budget
/// on top of the time already spent, overshooting the documented
/// single wall-clock budget on `timeout_ms`. Drives the helper
/// directly with a UDP socket pre-armed to a wide read_timeout
/// (mirroring the bind-time value) and asserts the re-arm
/// shrinks the timeout to track the call-wide deadline anchor.
#[test]
fn arm_recv_against_call_deadline_shrinks_read_timeout_against_call_anchor() {
    let socket = UdpSocket::bind("127.0.0.1:0").expect("bind");
    let bind_time_value = Duration::from_secs(5);
    socket
        .set_read_timeout(Some(bind_time_value))
        .expect("seed initial read_timeout");

    let total = Duration::from_millis(500);
    let elapsed = Duration::from_millis(200);
    let remaining = arm_recv_against_call_deadline(&socket, total, elapsed)
        .expect("non-zero remaining must yield Ok");

    let read_t = socket
        .read_timeout()
        .expect("read_timeout call ok")
        .expect("read timeout still set");
    assert_eq!(
        read_t, remaining,
        "set_read_timeout must reflect the helper's returned remaining",
    );
    assert!(
        read_t < bind_time_value,
        "re-armed read_timeout {read_t:?} must be strictly less than \
         the seeded bind-time value {bind_time_value:?}",
    );
    assert!(
        read_t < total,
        "re-armed read_timeout {read_t:?} must be strictly less than \
         the call-wide budget {total:?} once {elapsed:?} has elapsed",
    );
    assert!(
        read_t > Duration::ZERO,
        "non-zero remaining must yield a strictly positive timeout, \
         got {read_t:?}",
    );
}

/// Expired-budget arm of `arm_recv_against_call_deadline`. Once
/// the call-wide deadline has lapsed, the helper must
/// short-circuit with `Timeout(Ntp)` rather than handing back a
/// zero-length `Duration` (which `set_read_timeout` would reject
/// on most platforms) or letting the socket be re-armed at all —
/// the latter would drop the phase-tagged failure shape callers
/// rely on for attribution.
#[test]
fn arm_recv_against_call_deadline_short_circuits_after_expiry() {
    let socket = UdpSocket::bind("127.0.0.1:0").expect("bind");
    let initial = Duration::from_secs(5);
    socket
        .set_read_timeout(Some(initial))
        .expect("seed initial read_timeout");

    let total = Duration::from_millis(100);
    let elapsed = Duration::from_millis(150);
    match arm_recv_against_call_deadline(&socket, total, elapsed) {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::Ntp,
            trust_backend: None,
        }) => {}
        other => panic!("expired call-wide deadline must yield Timeout(Ntp), got {other:?}",),
    }
    let read_t = socket
        .read_timeout()
        .expect("read_timeout call ok")
        .expect("read timeout still set");
    assert_eq!(
        read_t, initial,
        "expired short-circuit must not re-arm the socket; got {read_t:?}",
    );
}

/// Pins `From<KeError> for NtsError` for every variant of the
/// `KeTimeoutPhase` taxonomy. The mapping is the load-bearing
/// hand-off between the KE layer's phase-tagged failure shape and
/// the public Dart-facing `NtsError::Timeout(TimeoutPhase)`
/// surface; a regression that drops one of the variants would
/// silently re-route the failure through `KeProtocol` (the
/// catch-all arm) and lose the attribution. The pre-existing
/// `connect_with_timeout_*` and `bind_connected_udp_*` tests cover
/// `Connect` and `DnsTimeout` end-to-end; this mapping test
/// closes the residual gap on `DnsSaturation`, `Tls`, and
/// `KeRecordIo`, and pins the full set together so the taxonomy
/// is checked exhaustively in one place.
#[test]
fn ke_phase_timeout_maps_to_nts_timeout_for_every_phase() {
    let cases = [
        (KeTimeoutPhase::DnsSaturation, TimeoutPhase::DnsSaturation),
        (KeTimeoutPhase::DnsTimeout, TimeoutPhase::DnsTimeout),
        (KeTimeoutPhase::Connect, TimeoutPhase::Connect),
        (KeTimeoutPhase::Tls, TimeoutPhase::Tls),
        (KeTimeoutPhase::KeRecordIo, TimeoutPhase::KeRecordIo),
    ];
    for (ke_phase, expected) in cases {
        let mapped = NtsError::from(KeError::PhaseTimeout(ke_phase));
        match mapped {
            NtsError::Timeout { phase: got, .. } => assert_eq!(
                got, expected,
                "KeTimeoutPhase::{ke_phase:?} mapped to NtsError::Timeout({got:?}); \
                 expected NtsError::Timeout({expected:?})",
            ),
            other => panic!(
                "KeTimeoutPhase::{ke_phase:?} produced {other:?}; \
                 expected NtsError::Timeout({expected:?})",
            ),
        }
    }
}

/// Pins `From<io::Error> for NtsError` for the UDP send/recv
/// path. Both `TimedOut` (the standard read/write-timeout
/// signal) and `WouldBlock` (the socket-non-blocking edge case
/// some platforms surface for an expired SO_RCVTIMEO) must land
/// on `Timeout(Ntp)` — that conversion site is reached only by
/// `socket.send` / `socket.recv` in `nts_query` (the KE pipeline
/// has its own phase-aware funnel, see the rustdoc on the
/// `From<io::Error>` impl), so `Ntp` is the only correct tag.
#[test]
fn io_error_timed_out_or_would_block_maps_to_timeout_ntp() {
    for kind in [std::io::ErrorKind::TimedOut, std::io::ErrorKind::WouldBlock] {
        let io_err = std::io::Error::from(kind);
        match NtsError::from(io_err) {
            NtsError::Timeout {
                phase: TimeoutPhase::Ntp,
                trust_backend: None,
            } => {}
            other => panic!(
                "io::Error of {kind:?} mapped to {other:?}; \
                 expected NtsError::Timeout(Ntp)",
            ),
        }
    }
}

/// End-to-end UDP send/recv-timeout regression. Binds a real
/// `UdpSocket` against an unbound loopback port, arms a tight
/// `SO_RCVTIMEO`, and proves that the `io::Error` the kernel
/// returns from `recv` flows through `From<io::Error> for
/// NtsError` as `Timeout(Ntp)`. This is the integration-level
/// counterpart to the mapping unit test above and pins the
/// "actual UDP send/recv timeout" path the public API surfaces
/// to callers diagnosing a stalled NTPv4 round-trip.
#[test]
fn udp_recv_timeout_surfaces_as_timeout_ntp() {
    let socket = UdpSocket::bind("127.0.0.1:0").expect("bind UDP socket");
    // Connect to a port we own but never read from, so any send
    // is silently absorbed and the recv has nothing to read.
    let absorber = UdpSocket::bind("127.0.0.1:0").expect("bind absorber");
    let absorber_addr = absorber.local_addr().expect("absorber local_addr");
    socket.connect(absorber_addr).expect("connect to absorber");
    socket
        .set_read_timeout(Some(Duration::from_millis(50)))
        .expect("set_read_timeout");

    let mut buf = [0u8; 16];
    let started = Instant::now();
    let io_err = socket
        .recv(&mut buf)
        .expect_err("recv with no peer must time out");
    let elapsed = started.elapsed();
    assert!(
        matches!(
            io_err.kind(),
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock,
        ),
        "recv produced {:?} (kind {:?}); expected TimedOut/WouldBlock",
        io_err,
        io_err.kind(),
    );
    assert!(
        elapsed < Duration::from_secs(2),
        "recv took {elapsed:?}; SO_RCVTIMEO did not fire",
    );
    match NtsError::from(io_err) {
        NtsError::Timeout {
            phase: TimeoutPhase::Ntp,
            trust_backend: None,
        } => {}
        other => panic!(
            "UDP recv timeout mapped to {other:?}; \
             expected NtsError::Timeout(Ntp)",
        ),
    }
}

/// Pins the `From<KePhaseTimings> for PhaseTimings` mapping.
/// The Dart-facing struct is reconstructed inside `nts_query` and
/// `nts_warm_cookies` from the KE-side breakdown; if a future
/// edit drops or reorders one of the four micro fields the
/// caller-visible timing dashboard would silently lose a phase.
#[test]
fn from_ke_phase_timings_for_phase_timings_preserves_all_micro_fields() {
    let ke = KePhaseTimings {
        dns_micros: 11,
        connect_micros: 22,
        tls_handshake_micros: 33,
        ke_record_io_micros: 44,
    };
    let pt: PhaseTimings = ke.into();
    assert_eq!(pt.dns_micros, 11);
    assert_eq!(pt.connect_micros, 22);
    assert_eq!(pt.tls_handshake_micros, 33);
    assert_eq!(pt.ke_record_io_micros, 44);
}

/// `Display for NtsError` is the format consumers see when an
/// error escapes the public API as a string. The `Timeout` arm
/// must include the phase tag verbatim — without it the new
/// taxonomy is invisible to anything reading
/// `format!("{e}")` rather than matching the enum directly.
#[test]
fn display_renders_timeout_with_phase_tag() {
    for phase in [
        TimeoutPhase::DnsSaturation,
        TimeoutPhase::DnsTimeout,
        TimeoutPhase::Connect,
        TimeoutPhase::Tls,
        TimeoutPhase::KeRecordIo,
        TimeoutPhase::Ntp,
    ] {
        let rendered = format!(
            "{}",
            NtsError::Timeout {
                phase,
                trust_backend: None
            }
        );
        let tag = format!("{phase:?}");
        assert!(
            rendered.contains(&tag),
            "Display for Timeout({phase:?}) was {rendered:?}; \
             expected to contain {tag:?}",
        );
    }
}

/// Pins the non-timeout half of `From<KeError> for NtsError`:
/// `KeError::Io` must surface as `NtsError::Network` with the
/// underlying diagnostic preserved, not collapsed into a
/// timeout. The phase-timeout half is exhausted by
/// `ke_phase_timeout_maps_to_nts_timeout_for_every_phase`; this
/// one guards against a future edit that mistakenly routes a
/// real I/O failure (NXDOMAIN, ECONNREFUSED, …) through the
/// timeout taxonomy.
#[test]
fn from_ke_error_io_routes_to_network_with_diagnostic() {
    let io = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "kex-refused");
    match NtsError::from(KeError::Io(io)) {
        NtsError::Network { message: msg, .. } => assert!(
            msg.contains("kex-refused"),
            "Network message {msg:?} dropped the underlying diagnostic",
        ),
        other => panic!("KeError::Io mapped to {other:?}; expected NtsError::Network",),
    }
}

/// Pins the call-wide budget contract `nts_query` enforces
/// between the KE phases and the UDP-setup leg. Once `elapsed`
/// reaches or exceeds `total`, the helper short-circuits with
/// `Timeout(Ntp)` rather than handing back `Duration::ZERO`
/// (which would let `bind_connected_udp_using` re-anchor a
/// near-zero deadline and emit a misleading `DnsTimeout` tag for
/// what is in fact a post-KE budget exhaustion). A non-zero
/// remainder propagates through unchanged, including the
/// boundary case where the slack is exactly one nanosecond.
/// Regression for the "single global wall-clock budget" claim
/// in the `nts_query` rustdoc; without this helper a cold query
/// could overshoot the caller's budget by up to 2x by re-arming
/// a fresh `timeout` for the UDP leg.
#[test]
fn remaining_budget_or_ntp_timeout_short_circuits_when_elapsed_meets_total() {
    let total = Duration::from_millis(100);
    // Slack remaining: helper hands the difference back unchanged.
    let r = remaining_budget_or_ntp_timeout(total, Duration::from_millis(40))
        .expect("non-zero slack must propagate");
    assert_eq!(r, Duration::from_millis(60));

    // Budget exactly consumed: short-circuit with Timeout(Ntp).
    match remaining_budget_or_ntp_timeout(total, total) {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::Ntp,
            trust_backend: None,
        }) => {}
        other => panic!("elapsed == total must yield Timeout(Ntp), got {other:?}"),
    }

    // Budget overrun: same short-circuit, no panic on saturating sub.
    match remaining_budget_or_ntp_timeout(total, total + Duration::from_millis(50)) {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::Ntp,
            trust_backend: None,
        }) => {}
        other => panic!("elapsed > total must yield Timeout(Ntp), got {other:?}"),
    }

    // Sub-microsecond slack still propagates as Ok.
    #[expect(
        clippy::unchecked_time_subtraction,
        reason = "test-local: `total` is a locally-constructed Duration \
                  well above 1 ns; underflow is impossible by construction"
    )]
    let nearly = total - Duration::from_nanos(1);
    let r = remaining_budget_or_ntp_timeout(total, nearly)
        .expect("one-nanosecond slack must propagate");
    assert_eq!(r, Duration::from_nanos(1));
}

// --- per-instance NtsClient / SessionTable cache layer ----------
//
// The `default_session_table` shim above already pins the
// checkout / deposit_cookies / evict_session invariants against
// the process-wide table; the tests in this section pin the
// *per-instance* invariants the public `NtsClient` handle relies
// on: lifecycle (`install`, `invalidate`, `clear`), per-instance
// isolation (a fresh `SessionTable` shares no state with another
// fresh `SessionTable` or with the default table), and the
// `bool` return contract on `invalidate`. These tests use plain
// `make_test_session` rather than running a real NTS-KE
// handshake, mirroring how the existing cache-layer tests
// exercise the deposit/evict paths without standing up a live KE
// responder.

/// Per-instance lifecycle: `install` adds an entry, `invalidate`
/// returns `true` on hit and removes it, `invalidate` on a
/// missing key returns `false` and is a no-op, and `clear`
/// drops every remaining entry in one call.
#[test]
fn session_table_install_invalidate_clear_round_trip() {
    let table = SessionTable::new();
    let spec_a = NtsServerSpec {
        host: "table-rt-a.invalid".into(),
        port: 4460,
    };
    let spec_b = NtsServerSpec {
        host: "table-rt-b.invalid".into(),
        port: 4460,
    };

    let key_a = session_key(&spec_a);
    let key_b = session_key(&spec_b);

    // Install A and B; both visible under their own keys.
    table.install(&spec_a, make_test_session("table-rt-a.invalid", 123, 1));
    table.install(&spec_b, make_test_session("table-rt-b.invalid", 124, 2));
    {
        let g = table.map.lock().expect("test session table poisoned");
        assert!(g.contains_key(&key_a), "spec A must be cached");
        assert!(g.contains_key(&key_b), "spec B must be cached");
    }

    // Invalidate A: returns true, A is gone, B survives.
    assert!(
        table.invalidate(&spec_a),
        "invalidate on a present entry must return true"
    );
    {
        let g = table.map.lock().expect("test session table poisoned");
        assert!(!g.contains_key(&key_a), "spec A must be evicted");
        assert!(g.contains_key(&key_b), "spec B must survive A's eviction");
    }

    // Re-invalidate A: now a no-op that returns false.
    assert!(
        !table.invalidate(&spec_a),
        "invalidate on a missing entry must return false (no-op)"
    );

    // Clear drops everything.
    table.clear();
    let g = table.map.lock().expect("test session table poisoned");
    assert!(
        g.is_empty(),
        "clear must drop every entry; remaining keys: {:?}",
        g.keys().collect::<Vec<_>>()
    );
}

/// Per-instance isolation: two fresh `SessionTable`s share no
/// state, and neither shares with the process-wide default
/// table. Pins acceptance criterion 3 from `nts-2dd` at the
/// cache layer (the public `NtsClient` wrapper inherits this
/// invariant by construction since each `NtsClient::new` mints
/// a fresh `SessionTable`).
#[test]
fn session_table_instances_are_independent() {
    let a = SessionTable::new();
    let b = SessionTable::new();
    let spec = NtsServerSpec {
        host: "table-iso.invalid".into(),
        port: 4460,
    };
    let key = session_key(&spec);

    a.install(&spec, make_test_session("table-iso.invalid", 200, 1));

    // B must be empty for this key.
    {
        let g = b.map.lock().expect("test session table poisoned");
        assert!(
            !g.contains_key(&key),
            "B must not see A's installed session",
        );
    }
    // A must still hold the entry it installed.
    {
        let g = a.map.lock().expect("test session table poisoned");
        assert!(g.contains_key(&key), "A must still hold its own entry");
    }
    // The default table must also not see A's entry. Wrapped in
    // an explicit clear so a stale entry from a previous test on
    // the default table cannot mask the assertion. The eviction
    // below is harmless even if the entry was never present.
    default_session_table().invalidate(&spec);
    {
        let g = default_session_table()
            .map
            .lock()
            .expect("default session table poisoned");
        assert!(
            !g.contains_key(&key),
            "default table must not see entries installed in a fresh SessionTable",
        );
    }

    // Symmetric cleanup so a parallel test on `a` does not see
    // the stub session we left behind here.
    a.clear();
}

/// `NtsClient::invalidate` and `NtsClient::clear` are thin
/// pass-throughs to the owned `SessionTable`. Pins the
/// `bool` return value on `invalidate` and the empty-after-clear
/// invariant at the public-handle layer so a future refactor
/// that drops the delegation surfaces here as well as in the
/// `SessionTable` tests above.
#[test]
fn nts_client_invalidate_and_clear_pass_through_to_table() {
    let client = NtsClient::new();
    let spec = NtsServerSpec {
        host: "client-pass-through.invalid".into(),
        port: 4460,
    };
    let key = session_key(&spec);

    // Empty client: invalidate returns false, no panic, table
    // still empty.
    assert!(
        !client.invalidate(spec.clone()),
        "invalidate on a fresh client must return false",
    );

    // Install via the inner table, then invalidate via the
    // public method. Returns true; the entry is gone.
    client.table.install(
        &spec,
        make_test_session("client-pass-through.invalid", 1, 1),
    );
    assert!(
        client.invalidate(spec.clone()),
        "invalidate on an installed entry must return true",
    );
    {
        let g = client.table.map.lock().expect("client table poisoned");
        assert!(!g.contains_key(&key), "entry must be evicted");
    }

    // `clear` drops everything in one call. Install several
    // entries first so a single-entry clear cannot pass by
    // accident.
    for i in 0..3u16 {
        let s = NtsServerSpec {
            host: format!("client-clear-{i}.invalid"),
            port: 4460 + i,
        };
        client
            .table
            .install(&s, make_test_session(&s.host, 1, (10 + i).into()));
    }
    client.clear();
    let g = client.table.map.lock().expect("client table poisoned");
    assert!(
        g.is_empty(),
        "clear must drop every entry; remaining: {:?}",
        g.keys().collect::<Vec<_>>()
    );
}

/// `validate` rejects an empty host / zero port before any cache
/// or network work happens, on both the per-client surface
/// (`NtsClient::query`, `NtsClient::warm_cookies`) and the
/// top-level free function (`nts_warm_cookies`). Companions to
/// the existing pre-3.1 validation tests for `nts_query`.
///
/// Operationally redundant because the four delegation paths all
/// land in the same `validate(&spec)?` line in the `_inner`
/// helpers; pinning each call site individually is what gives
/// codecov a covered patch line on the per-client method bodies
/// and on the top-level `nts_warm_cookies` 1-line delegation,
/// which would otherwise stay uncovered until the first happy-
/// path Rust unit test (currently only the live integration
/// probes against real NTS endpoints, gated behind `--ignored`).
#[test]
fn nts_client_query_rejects_invalid_spec_via_validate() {
    let client = NtsClient::new();
    let spec = NtsServerSpec {
        host: String::new(),
        port: 4460,
    };
    match client.query(spec, 1000, 1) {
        Err(NtsError::InvalidSpec(_)) => {}
        other => panic!("expected InvalidSpec, got {other:?}"),
    }
}

#[test]
fn nts_client_warm_cookies_rejects_invalid_spec_via_validate() {
    let client = NtsClient::new();
    let spec = NtsServerSpec {
        host: "ok.invalid".to_owned(),
        port: 0,
    };
    match client.warm_cookies(spec, 1000, 1) {
        Err(NtsError::InvalidSpec(_)) => {}
        other => panic!("expected InvalidSpec, got {other:?}"),
    }
}

#[test]
fn nts_warm_cookies_top_level_rejects_invalid_spec_via_validate() {
    let spec = NtsServerSpec {
        host: String::new(),
        port: 4460,
    };
    match nts_warm_cookies(spec, 1000, 1) {
        Err(NtsError::InvalidSpec(_)) => {}
        other => panic!("expected InvalidSpec, got {other:?}"),
    }
}

/// End-to-end fail-fast eviction routed through `NtsClient::query`
/// rather than the top-level `nts_query`. Mirrors the shape of
/// `nts_query_evicts_session_on_aead_authentication_failure`
/// (which exercises the same path through the process-wide
/// default client) but pre-installs the session in the
/// per-client table and asserts the eviction happened on
/// *this* client's table — not the default. Pins:
///
/// 1. `NtsClient::query` actually delegates to `nts_query_inner`
///    against `self.table` rather than against the default
///    table.
/// 2. The fail-fast eviction landed on the per-client table:
///    after the call, the entry is gone from the client's
///    table, and the default table still does not see one for
///    this `host:port`.
#[test]
fn nts_client_query_evicts_session_on_aead_failure_in_client_table() {
    let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
    faux_server
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("set faux server read timeout");
    let server_port = faux_server.local_addr().expect("local addr").port();
    let host = "127.0.0.1";
    let key = format!("{host}:{server_port}");

    let client = NtsClient::new();
    let generation = next_session_generation();
    let mut session = make_test_session(host, server_port, generation);
    session.jar.put_many(host, [vec![0xAB; 32]]);
    client
        .table
        .map
        .lock()
        .expect("client table poisoned")
        .insert(key.clone(), session);

    let handler = std::thread::spawn(move || {
        let mut buf = [0u8; 2048];
        let (n, src) = faux_server
            .recv_from(&mut buf)
            .expect("faux server recv_from");
        // Same mode-bit flip as the default-client test: forces
        // the AEAD verify in `parse_server_response` to trip a
        // tag mismatch and raise `NtpError::Aead`, which is the
        // canonical rekey signal `nts_query_inner` evicts on.
        buf[0] = (buf[0] & !0b0000_0111) | 0b0000_0100;
        faux_server
            .send_to(&buf[..n], src)
            .expect("faux server send_to");
    });

    let spec = NtsServerSpec {
        host: host.to_owned(),
        port: server_port,
    };
    let result = client.query(spec.clone(), 2_000, 64);
    handler.join().expect("faux server thread panicked");

    match result {
        Err(NtsError::Authentication { .. }) => {}
        other => panic!("expected NtsError::Authentication, got {other:?}"),
    }

    // Eviction landed on the client's own table.
    let g = client.table.map.lock().expect("client table poisoned");
    assert!(
        g.get(&key).is_none(),
        "fail-fast eviction must remove the entry from the per-client table",
    );
    drop(g);

    // And the default table was not touched (we never installed
    // anything there for this `host:port`, and the per-client
    // call should not have leaked into it).
    let g = default_session_table()
        .map
        .lock()
        .expect("default session table poisoned");
    assert!(
        g.get(&key).is_none(),
        "per-client query must not touch the default table",
    );
}

// ------------------------------------------------------------------
// Live integration probes — `nts-dbg` Avenue 0.
//
// These tests perform real NTS-KE handshakes and authenticated NTPv4
// exchanges against Cloudflare's public endpoint
// (`time.cloudflare.com`). They are the happy-path coverage layer
// flagged by `nts-dbg`: the prior `#[ignore]`d single probe gave the
// code paths zero codecov contribution, leaving `nts_query_inner` and
// `nts_warm_cookies_inner` at ~70% line coverage with the gap entirely
// in the post-handshake success arms. The four probes below cover the
// `nts_query` / `NtsClient::query` and `nts_warm_cookies` /
// `NtsClient::warm_cookies` quartet, each through the retry wrapper.
//
// Transient-vs-fatal classification: `Network` and `Timeout` are the
// only variants that retry. Everything else (`KeProtocol`,
// `NtpProtocol`, `Authentication`, `NoCookies`,
// `TrustBackendUnavailable`, `Internal`, `InvalidSpec`) panics
// immediately with the full diagnostic — those signal real protocol or
// crate-level bugs, not network weather, and silencing them under
// retry would erase the entire reason for running against a live
// server. Three attempts with 500ms / 1000ms backoff keeps total
// added wall-clock under 2s on the happy path and bounded on flakes.
// ------------------------------------------------------------------

/// Returns `true` for `NtsError` variants that we treat as network
/// weather rather than a real failure — `Network` (TCP/UDP I/O,
/// connection failure) and `Timeout` (any phase tripped its deadline).
/// Every other variant indicates a protocol-level or crate-level
/// problem the live probes should surface, not paper over.
fn is_transient_nts_error(err: &NtsError) -> bool {
    matches!(err, NtsError::Network { .. } | NtsError::Timeout { .. })
}

/// Retry `f` up to three times on `is_transient_nts_error` failures
/// with 500ms / 1000ms back-off between attempts. Returns the success
/// value on the first non-transient outcome; panics with the full
/// diagnostic on any non-transient error, or — after the third
/// transient failure exhausts the budget — panics with the *trail*
/// of every transient error observed across the three attempts, in
/// attempt order. The trail distinguishes a sustained Cloudflare
/// outage (three matching errors) from a single bad sample followed
/// by recovery flicker (mixed shapes) during the `nts-dbg` Avenue 0
/// flake-rate measurement window. `label` is included in stderr
/// retry notices and in the final panic message so test logs name
/// the probe.
fn retry_on_transient<T, F>(label: &str, mut f: F) -> T
where
    F: FnMut() -> Result<T, NtsError>,
{
    const ATTEMPTS: u32 = 3;
    let mut attempt: u32 = 0;
    let mut history: Vec<NtsError> = Vec::with_capacity(ATTEMPTS as usize);
    loop {
        attempt += 1;
        match f() {
            Ok(v) => return v,
            Err(e) if !is_transient_nts_error(&e) => {
                panic!(
                    "{label} failed on attempt {attempt}/{ATTEMPTS} with non-transient error: {e:?}",
                );
            }
            Err(e) if attempt >= ATTEMPTS => {
                history.push(e);
                panic!(
                    "{label} exhausted {ATTEMPTS} retry attempts; transient error trail: {history:?}",
                );
            }
            Err(e) => {
                eprintln!(
                    "{label}: transient failure on attempt {attempt}/{ATTEMPTS}: {e:?}; retrying",
                );
                history.push(e);
                std::thread::sleep(Duration::from_millis(500 * attempt as u64));
            }
        }
    }
}

/// Helper: assert that an `NtsTimeSample` from Cloudflare's public
/// endpoint has the expected shape. Centralised so both query-shaped
/// probes (top-level `nts_query` and `NtsClient::query`) share one
/// assertion vocabulary.
///
/// Numerical lower bounds (`round_trip_micros >= 1_000`,
/// `fresh_cookies >= 1`) were measured against `time.cloudflare.com`
/// on 2026-05-16 (15 fresh-KE samples from a developer machine,
/// nts-dx2 sampling harness): RTT min 26 116 µs, median 31 467 µs,
/// max 39 770 µs (26-40 ms range, all ≥ 26× the chosen 1 000 µs
/// floor); `fresh_cookies` was exactly 2 on every sample. The RTT
/// floor catches "calculation collapsed to ~0" regressions without
/// flaking on either developer-machine variance or GHA-runner-to-
/// Cloudflare variance (a Linux runner co-located with a Cloudflare
/// PoP would still see > 1 000 µs by an order of magnitude). The
/// `fresh_cookies >= 1` bound is the substantive protocol minimum
/// (without at least one fresh cookie, every subsequent query would
/// re-handshake); a hard pin to 2 would catch a regression in
/// Cloudflare's cookie-buffer policy but would also flake the day
/// Cloudflare moves to 1 or 3, so the soft floor is preferred.
fn assert_cloudflare_time_sample(sample: &NtsTimeSample) {
    assert_eq!(sample.aead_id, aead_ids::AES_SIV_CMAC_256);
    assert!(sample.server_stratum > 0 && sample.server_stratum < 16);
    assert!(
        sample.round_trip_micros >= 1_000,
        "round_trip_micros {} µs is implausibly low for a real Cloudflare \
         query (measured min ~26 ms on 2026-05-16); RTT calculation may \
         have collapsed to ~0",
        sample.round_trip_micros,
    );
    // RFC 8915 caps cookies-out at 8; Cloudflare currently returns 2
    // (measured 2026-05-16), but the substantive invariant is "at
    // least one fresh cookie was delivered" — without that, the
    // session jar drains across queries and every subsequent query
    // re-handshakes.
    assert!(
        sample.fresh_cookies >= 1 && sample.fresh_cookies <= 8,
        "fresh_cookies = {} outside the expected 1..=8 range",
        sample.fresh_cookies,
    );
    // Sanity: server time should be within ±5 minutes of local time.
    let now_us = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as i64)
        .unwrap_or(0);
    assert!(
        (sample.utc_unix_micros - now_us).abs() < 5 * 60 * 1_000_000,
        "server time {}us local time {}us",
        sample.utc_unix_micros,
        now_us,
    );
}

/// Live integration probe — real NTS-KE handshake and authenticated
/// NTPv4 exchange against `time.cloudflare.com` via the top-level
/// `nts_query` function (default-client path). Promoted out of
/// `#[ignore]` by `nts-dbg`: the standard CI runner has outbound
/// TCP/4460 + UDP/123 to Cloudflare, and transient network blips are
/// absorbed by `retry_on_transient` so a flake re-runs rather than
/// failing the suite. A protocol-level error (KE record validation,
/// AEAD verify, etc.) is not retried — that signals a real bug.
///
/// Deliberately a single-call probe. The default singleton's session
/// table is shared with `nts_warm_cookies_live_cloudflare` (and any
/// future free-fn live probe), so a "second call reuses cached
/// session" assertion here would be order-dependent: whichever live
/// probe ran first would prime the cache for the others. The
/// per-client reuse semantics are tested deterministically by
/// `nts_query_live_cloudflare_via_client` below, which owns its own
/// session table.
#[test]
fn nts_query_live_cloudflare() {
    let spec = NtsServerSpec {
        host: "time.cloudflare.com".to_owned(),
        port: DEFAULT_KE_PORT,
    };
    let sample = retry_on_transient("nts_query cloudflare", || {
        nts_query(spec.clone(), 10_000, 0)
    });
    assert_cloudflare_time_sample(&sample);
}

/// Live probe through the per-client API surface: `NtsClient::query`
/// against `time.cloudflare.com` on a fresh client whose session table
/// is independent of the default singleton's. Exercises the same
/// post-handshake success arms as `nts_query_live_cloudflare` but
/// drives them through the method delegation path, which `nts-dbg`
/// flagged as separately uncovered in codecov even though it shares
/// `nts_query_inner` with the free function.
///
/// Doubles as the deterministic cache-reuse probe: the second call
/// asserts that all KE-phase timings are zero, which is the
/// observable signal of a cache hit (the cached-session branch skips
/// connect / TLS / KE-record-IO entirely). Safe to assert strictly
/// here — the per-client `SessionTable` has its own singleflight
/// `inflight` map, so no other test in the suite can land as a leader
/// or waiter against this client's table.
#[test]
fn nts_query_live_cloudflare_via_client() {
    let spec = NtsServerSpec {
        host: "time.cloudflare.com".to_owned(),
        port: DEFAULT_KE_PORT,
    };
    let client = NtsClient::new();
    let sample = retry_on_transient("NtsClient::query cloudflare (fresh)", || {
        client.query(spec.clone(), 10_000, 0)
    });
    assert_cloudflare_time_sample(&sample);

    let sample2 = retry_on_transient("NtsClient::query cloudflare (reuse)", || {
        client.query(spec.clone(), 10_000, 0)
    });
    assert_cloudflare_time_sample(&sample2);
    // Cache-hit signal: the cached-session branch skips connect /
    // TLS / KE-record-IO. `dns_micros` may be non-zero on the second
    // call (the UDP-path NTPv4-host lookup still runs), so don't
    // assert it.
    assert_eq!(
        sample2.phase_timings.connect_micros, 0,
        "second per-client query must hit the cache (connect_micros)",
    );
    assert_eq!(
        sample2.phase_timings.tls_handshake_micros, 0,
        "second per-client query must hit the cache (tls_handshake_micros)",
    );
    assert_eq!(
        sample2.phase_timings.ke_record_io_micros, 0,
        "second per-client query must hit the cache (ke_record_io_micros)",
    );
}

/// Live probe of `nts_warm_cookies` (top-level free function) against
/// `time.cloudflare.com`. `nts_warm_cookies` always runs a fresh KE
/// handshake (no cached-session short-circuit), so this exercises the
/// KE-only path without a subsequent NTPv4 exchange — coverage that
/// the query-shaped probes above do not provide.
///
/// `fresh_cookies > 0` is the substantive interop signal: a
/// successful KE handshake against Cloudflare always returns at least
/// one cookie. We deliberately do *not* assert on `phase_timings`
/// fields here — under the singleflight machinery
/// `SessionTable::warm_cookies` uses, a concurrent caller that lands
/// as a waiter receives the leader's `fresh_cookies` payload but
/// reports `KePhaseTimings::default()` (all zeros) because it did no
/// KE work itself. The four live probes in this section run in
/// parallel by default, so any of them landing as a waiter would
/// trip a `phase_timings > 0` assertion.
#[test]
fn nts_warm_cookies_live_cloudflare() {
    let spec = NtsServerSpec {
        host: "time.cloudflare.com".to_owned(),
        port: DEFAULT_KE_PORT,
    };
    let outcome = retry_on_transient("nts_warm_cookies cloudflare", || {
        nts_warm_cookies(spec.clone(), 10_000, 0)
    });
    assert!(
        outcome.fresh_cookies > 0,
        "warm_cookies must harvest at least one cookie; got {}",
        outcome.fresh_cookies,
    );
}

/// Live probe of `NtsClient::warm_cookies` (per-client method) against
/// `time.cloudflare.com`. Same KE-only handshake path as the free-
/// function probe above, driven through the method delegation surface
/// on a fresh `NtsClient` whose session table is independent of the
/// default singleton's. See `nts_warm_cookies_live_cloudflare` for
/// why phase-timing assertions are deliberately omitted.
#[test]
fn nts_warm_cookies_live_cloudflare_via_client() {
    let spec = NtsServerSpec {
        host: "time.cloudflare.com".to_owned(),
        port: DEFAULT_KE_PORT,
    };
    let client = NtsClient::new();
    let outcome = retry_on_transient("NtsClient::warm_cookies cloudflare", || {
        client.warm_cookies(spec.clone(), 10_000, 0)
    });
    assert!(
        outcome.fresh_cookies > 0,
        "warm_cookies must harvest at least one cookie; got {}",
        outcome.fresh_cookies,
    );
}

/// IPv6-capable live probe — exercises the dual-stack code path
/// against PTB's public NTS endpoint. PTB publishes AAAA records,
/// so on a host that prefers IPv6 (RFC 6724 default) this drives
/// the `[::]:0` bind branch. Kept behind `#[ignore]` even after
/// `nts-dbg` un-gated the Cloudflare probes above: GitHub Actions
/// Linux runners have inconsistent IPv6 connectivity by Azure
/// region, and this test's existing semantics are "skip gracefully
/// on network failure" rather than "retry then fail". Mixing those
/// two modes under the same retry wrapper would either spam stderr
/// with retry notices on the common no-IPv6 path or turn a real
/// PTB outage into a silent skip. Run manually with:
///   cargo test -p nts_rust nts_query_live_ipv6 -- --ignored --nocapture
#[test]
#[ignore = "requires outbound TCP/4460 + UDP/123 IPv6 to ptbtime1.ptb.de"]
fn nts_query_live_ipv6_ptb() {
    let spec = NtsServerSpec {
        host: "ptbtime1.ptb.de".to_owned(),
        port: DEFAULT_KE_PORT,
    };
    match nts_query(spec, 10_000, 0) {
        Ok(sample) => {
            assert!(sample.server_stratum > 0 && sample.server_stratum < 16);
            assert!(sample.round_trip_micros > 0);
        }
        Err(NtsError::Network { message: msg, .. }) => {
            eprintln!("skipping: no IPv6 path to ptbtime1.ptb.de ({msg})");
        }
        Err(other) => panic!("unexpected non-network failure: {other:?}"),
    }
}

// ------------------------------------------------------------------
// Singleflight: concurrent cold queries against the same host
// collapse onto one handshake; concurrent queries against different
// hosts run their handshakes in parallel; per-call deadlines are
// honoured by waiters; leader failures propagate to every waiter as
// a cloned `NtsError`. See `nts-o8u` for the full design.
// ------------------------------------------------------------------

use std::sync::atomic::AtomicUsize;
use std::thread;

/// Build a `Session` with `cookie_count` cookies in the jar so the
/// post-handshake cookie-take phase succeeds without standing up a
/// real KE responder. Cookies are 8-byte sentinels; the singleflight
/// tests never seal or open them.
fn make_test_session_with_cookies(
    host: &str,
    ntpv4_port: u16,
    generation: u64,
    cookie_count: usize,
) -> Session {
    let mut s = make_test_session(host, ntpv4_port, generation);
    let cookies: Vec<Vec<u8>> = (0..cookie_count)
        .map(|i| (i as u64).to_le_bytes().to_vec())
        .collect();
    s.jar.put_many(host, cookies);
    s
}

/// Spin until `predicate` returns true, polling the singleflight
/// state at 1ms intervals up to `timeout`. Replaces the
/// `thread::sleep(50ms)` heuristics the singleflight tests
/// originally used to wait for "leader has registered" or "all
/// waiters have grabbed a slot reference" — those are deterministic
/// signals the test can read off `table.inflight` directly, so
/// there's no need for a fixed-duration sleep that flakes on slow
/// or contended CI runners. Panics with a descriptive message if
/// the predicate never becomes true; that is a real test failure
/// (a regression that prevents the singleflight from registering
/// or that loses waiter references) rather than a hang.
fn await_singleflight_state<F>(table: &SessionTable, key: &str, timeout: Duration, predicate: F)
where
    F: Fn(Option<&Arc<HandshakeSlot>>) -> bool,
{
    let deadline = Instant::now() + timeout;
    loop {
        {
            let g = table
                .inflight
                .lock()
                .expect("inflight singleflight map poisoned in test");
            if predicate(g.get(key)) {
                return;
            }
        }
        assert!(
            Instant::now() < deadline,
            "singleflight state did not converge for key {key:?} within {timeout:?}; \
             this almost certainly means the leader never registered an inflight \
             slot or the waiters never grabbed their slot references",
        );
        thread::sleep(Duration::from_millis(1));
    }
}

/// One-shot release primitive used by the singleflight tests to
/// park a leader handshake closure until the assertion-side
/// preconditions are met. Replaces `Barrier::new(2)` for these
/// cases because `std::sync::Barrier::wait` has no built-in
/// timeout — if the test thread panics before reaching the
/// matching `wait` (for example because `await_singleflight_state`
/// times out on a regression), the leader thread parks forever
/// and `cargo test` would have to rely on Rust's process exit to
/// reclaim it.
///
/// Two layers of safety net:
///
/// 1. `ReleaseHandle::wait_release` is bounded by a per-call
///    `timeout` so even a leader running with a torn-down test
///    thread cannot park indefinitely; on timeout it returns
///    `Err(())` and the closure can surface a synthetic error.
/// 2. `BoundedRelease`'s `Drop` impl signals release as part of
///    stack unwind. When the test panics, the local
///    `BoundedRelease` is dropped, which fires `release()`,
///    which unparks the leader closure immediately rather than
///    making it ride out the full `wait_release` deadline. The
///    `Arc<(Mutex, Condvar)>` survives long enough for the
///    closure to wake (it is held independently by every
///    `ReleaseHandle`) so the wakeup path is sound even when
///    the original is mid-drop.
struct BoundedRelease {
    state: Arc<(Mutex<bool>, Condvar)>,
}

/// Cloneable handle to a `BoundedRelease`'s shared state. The
/// handle is what the leader handshake closure captures and
/// parks on; the test thread retains the `BoundedRelease`
/// itself so its `Drop` can wake every parked handle on panic.
#[derive(Clone)]
struct ReleaseHandle {
    state: Arc<(Mutex<bool>, Condvar)>,
}

impl BoundedRelease {
    fn new() -> Self {
        Self {
            state: Arc::new((Mutex::new(false), Condvar::new())),
        }
    }

    fn handle(&self) -> ReleaseHandle {
        ReleaseHandle {
            state: self.state.clone(),
        }
    }

    /// Signal release. Idempotent — calling release twice (e.g.
    /// once explicitly from the test, once again from `Drop`)
    /// is a no-op the second time. Wakes every handle parked
    /// on `wait_release`.
    fn release(&self) {
        let (lock, cv) = &*self.state;
        *lock.lock().expect("BoundedRelease state poisoned") = true;
        cv.notify_all();
    }
}

impl Drop for BoundedRelease {
    fn drop(&mut self) {
        self.release();
    }
}

impl ReleaseHandle {
    /// Park until released or `timeout` elapses. Returns `Ok(())`
    /// when released, `Err(())` on timeout. The handshake closure
    /// translates `Err(())` into a synthetic `NtsError::Internal`
    /// so a stuck test (released-via-Drop or genuinely timed out)
    /// surfaces as a test failure rather than as a leader thread
    /// that completes successfully.
    fn wait_release(&self, timeout: Duration) -> Result<(), ()> {
        let (lock, cv) = &*self.state;
        let mut released = lock.lock().expect("BoundedRelease state poisoned");
        let deadline = Instant::now() + timeout;
        while !*released {
            let now = Instant::now();
            if now >= deadline {
                return Err(());
            }
            let (next, _) = cv
                .wait_timeout(released, deadline - now)
                .expect("BoundedRelease state poisoned");
            released = next;
        }
        Ok(())
    }
}

/// Acceptance criterion 1: N concurrent cold checkouts against the
/// same host collapse onto exactly one `establish_session` call.
/// Pre-singleflight, every concurrent caller would have run its own
/// handshake — verified by the same test against the pre-refactor
/// path would observe `handshake_count == N`.
#[test]
fn checkout_collapses_concurrent_cold_queries_onto_one_handshake() {
    const N: usize = 6;
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "singleflight-collapse.test".into(),
        port: 4460,
    };
    let handshake_count = Arc::new(AtomicUsize::new(0));
    // Park the leader's handshake until the test confirms every
    // follower has reached phase B and elected the leader's slot,
    // then release. Without the park, a fast leader could complete
    // before the followers ever entered checkout. `BoundedRelease`
    // (in place of `Barrier::new(2)`) is bounded by a per-call
    // wait timeout *and* by a `Drop`-on-panic release, so a test
    // that panics in `await_singleflight_state` cannot strand the
    // leader thread.
    let release = BoundedRelease::new();
    let release_handle = release.handle();
    let do_handshake = {
        let handshake_count = handshake_count.clone();
        move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            handshake_count.fetch_add(1, Ordering::SeqCst);
            release_handle
                .wait_release(Duration::from_secs(10))
                .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
            Ok((
                make_test_session_with_cookies(&spec.host, 123, next_session_generation(), N + 2),
                KePhaseTimings::default(),
            ))
        }
    };

    let handles: Vec<_> = (0..N)
        .map(|_| {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table
                    .checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                    .map(|(ctx, _)| ctx)
            })
        })
        .collect();

    // Wait until every spawned thread has reached phase B and one
    // has elected itself as the leader (registered the inflight
    // slot) and N-1 have elected as waiters (each holding a clone
    // of the slot Arc). The slot's `Arc::strong_count` reaches
    // `1 (inflight map) + 1 (LeaderGuard) + (N-1) (waiters)` =
    // `N + 1` exactly when every concurrent caller has made its
    // role-election decision; polling against that count
    // replaces the original `thread::sleep(50ms)` with a
    // deterministic singleflight-state signal that does not flake
    // under CI scheduling jitter.
    let key = session_key(&spec);
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
        slot.is_some_and(|s| Arc::strong_count(s) == N + 1)
    });
    release.release();

    let mut ok_count = 0;
    for h in handles {
        let result = h.join().expect("checkout thread panicked");
        if let Err(e) = result {
            panic!("checkout failed: {e:?}");
        }
        ok_count += 1;
    }
    assert_eq!(ok_count, N, "every concurrent checkout returned a context");
    assert_eq!(
        handshake_count.load(Ordering::SeqCst),
        1,
        "exactly one handshake ran across {N} concurrent cold checkouts",
    );
}

/// Acceptance criterion 2: concurrent checkouts against *different*
/// hosts continue to run their handshakes in parallel. The
/// singleflight is keyed by `session_key(spec)` (i.e. `host:port`),
/// so two different keys must each elect their own leader and the
/// two handshakes must be in-flight simultaneously. Verified by
/// gating the per-host handshakes on a shared rendezvous counter
/// with a bounded deadline: each leader increments
/// `arrived_count`, then polls until it sees `arrived_count == 2`.
/// If singleflight regresses and serialises the two handshakes,
/// the second leader never arrives, the first leader's poll
/// deadline elapses, and the closure surfaces a synthetic
/// `NtsError::Internal` so the test fails fast instead of
/// hanging the CI job indefinitely (cargo test has no built-in
/// per-test timeout and CI runs `cargo test --lib` without an
/// external timeout wrapper).
#[test]
fn checkout_does_not_serialize_handshakes_across_distinct_hosts() {
    let table = Arc::new(SessionTable::new());
    let spec_a = NtsServerSpec {
        host: "singleflight-host-a.test".into(),
        port: 4460,
    };
    let spec_b = NtsServerSpec {
        host: "singleflight-host-b.test".into(),
        port: 4460,
    };
    let arrived_count = Arc::new(AtomicUsize::new(0));
    let do_handshake = {
        let arrived_count = arrived_count.clone();
        move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            // Prove both handshakes are in flight at the same
            // time: each leader announces its arrival, then
            // polls until the partner has also announced.
            // Bounded by a 10s deadline so a regression that
            // serialises the leaders surfaces as a test
            // failure rather than as a hang against cargo's
            // per-test timeout.
            arrived_count.fetch_add(1, Ordering::SeqCst);
            let deadline = Instant::now() + Duration::from_secs(10);
            while arrived_count.load(Ordering::SeqCst) < 2 {
                if Instant::now() >= deadline {
                    return Err(NtsError::Internal(
                        "parallel-hosts rendezvous never reached 2 leaders".into(),
                    ));
                }
                thread::sleep(Duration::from_millis(1));
            }
            Ok((
                make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
                KePhaseTimings::default(),
            ))
        }
    };

    let h_a = {
        let table = table.clone();
        let spec_a = spec_a.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table.checkout_with(&spec_a, Duration::from_secs(10), 4, &do_handshake)
        })
    };
    let h_b = {
        let table = table.clone();
        let spec_b = spec_b.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table.checkout_with(&spec_b, Duration::from_secs(10), 4, &do_handshake)
        })
    };

    if let Err(e) = h_a.join().expect("host-a thread panicked") {
        panic!("host-a checkout failed: {e:?}");
    }
    if let Err(e) = h_b.join().expect("host-b thread panicked") {
        panic!("host-b checkout failed: {e:?}");
    }
}

/// Acceptance criterion 3: a waiter whose per-call deadline expires
/// before the leader finishes returns `NtsError::Timeout`, *not*
/// `NtsError::Internal` and not an indefinite block. The leader
/// here parks against a release channel so the test owns when (or
/// whether) it ever completes.
#[test]
fn checkout_waiter_returns_timeout_when_leader_outlasts_deadline() {
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "singleflight-waiter-timeout.test".into(),
        port: 4460,
    };
    let leader_release = BoundedRelease::new();
    let leader_release_handle = leader_release.handle();
    let do_handshake = move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
        leader_release_handle
            .wait_release(Duration::from_secs(10))
            .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
        Ok((
            make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
            KePhaseTimings::default(),
        ))
    };

    // Spawn the leader. It will park inside `do_handshake` until
    // we release `leader_release` at the end of the test.
    let leader = {
        let table = table.clone();
        let spec = spec.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || table.checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake))
    };

    // Wait until the leader has actually registered an inflight
    // slot before spawning the waiter. Without this gate the
    // waiter could enter checkout *first*, become the leader
    // itself, and run a handshake — which would fail the test
    // (waiter expected to see Timeout, would instead see Ok or
    // a leader-failure shape). Replaces the original
    // `thread::sleep(50ms)` with a deterministic state signal.
    let key = session_key(&spec);
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| slot.is_some());

    // Waiter has a tight 100ms call budget; leader is parked, so
    // the waiter must surface a Timeout once 100ms elapse.
    let waiter_started = Instant::now();
    let waiter_outcome = table.checkout_with(
        &spec,
        Duration::from_millis(100),
        4,
        &|_: &NtsServerSpec, _t: Duration, _c: usize| {
            panic!("waiter should never run a handshake; it must park on the leader's slot")
        },
    );
    let waiter_elapsed = waiter_started.elapsed();

    match waiter_outcome {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::KeRecordIo,
            trust_backend: None,
        }) => {}
        Err(other) => panic!("expected Timeout(KeRecordIo); got {other:?}"),
        Ok(_) => panic!("waiter returned Ok despite a parked leader"),
    }
    assert!(
        waiter_elapsed >= Duration::from_millis(100),
        "waiter returned before its 100ms budget elapsed: {waiter_elapsed:?}",
    );
    assert!(
        waiter_elapsed < Duration::from_millis(2_000),
        "waiter overshot its budget by >2s; deadline plumbing is broken: {waiter_elapsed:?}",
    );

    // Release the leader so its thread joins cleanly.
    leader_release.release();
    if let Err(e) = leader.join().expect("leader thread panicked") {
        panic!("leader checkout failed: {e:?}");
    }
}

/// Acceptance criterion 4: when the leader's handshake fails,
/// every waiter receives a cloned `NtsError` with the *same*
/// variant/payload as the leader. Waiters must not silently retry
/// (which would amplify load against a server that just rejected
/// the leader's handshake) and must not see `NtsError::Internal`
/// (which would mask the real failure shape under a sentinel).
#[test]
fn checkout_propagates_leader_failure_to_every_waiter() {
    const N: usize = 4;
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "singleflight-leader-fail.test".into(),
        port: 4460,
    };
    let handshake_count = Arc::new(AtomicUsize::new(0));
    let release = BoundedRelease::new();
    let release_handle = release.handle();
    let do_handshake = {
        let handshake_count = handshake_count.clone();
        move |_: &NtsServerSpec, _t: Duration, _c: usize| {
            handshake_count.fetch_add(1, Ordering::SeqCst);
            release_handle
                .wait_release(Duration::from_secs(10))
                .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
            Err(NtsError::KeProtocol {
                message: "synthetic leader-failure for singleflight test".into(),
                trust_backend: None,
            })
        }
    };

    let handles: Vec<_> = (0..N)
        .map(|_| {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
            })
        })
        .collect();

    // Same deterministic release pattern as criterion-1: wait
    // until every spawned thread has reached phase B, with one
    // leader (registered the inflight slot) and N-1 waiters
    // (each holding a clone of the slot Arc), before allowing
    // the leader to finish with a failure. Otherwise late
    // arrivals would observe an empty inflight after the
    // leader's `complete` and start their own (now-real)
    // handshakes, which would fail the `handshake_count == 1`
    // assertion below for reasons unrelated to the singleflight
    // fan-out semantic this test is verifying.
    let key = session_key(&spec);
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
        slot.is_some_and(|s| Arc::strong_count(s) == N + 1)
    });
    release.release();

    for h in handles {
        let result = h.join().expect("thread panicked");
        match result {
            Err(NtsError::KeProtocol { message: msg, .. }) => {
                assert_eq!(msg, "synthetic leader-failure for singleflight test");
            }
            Err(other) => {
                panic!("expected the leader's KeProtocol; got {other:?}")
            }
            Ok(_) => panic!("checkout returned Ok despite the leader failing"),
        }
    }
    assert_eq!(
        handshake_count.load(Ordering::SeqCst),
        1,
        "exactly one handshake ran; waiters did not silently retry",
    );
}

/// Acceptance criterion 5 (and a regression guard): the existing
/// session-generation invariant — every install mints a *distinct*
/// generation, even when multiple leaders run back-to-back through
/// the singleflight loop — survives the refactor. Without this,
/// `deposit_cookies` could silently accept stale cookies from a
/// superseded session, which is exactly the race the generation
/// counter exists to prevent. A failing assertion here would mean
/// the singleflight is sharing generation values across handshakes,
/// not that the singleflight is broken per se.
#[test]
fn checkout_consecutive_handshakes_get_distinct_generations() {
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "singleflight-generations.test".into(),
        port: 4460,
    };
    // Each handshake delivers exactly 1 cookie, so the next caller
    // re-enters phase B and triggers another handshake.
    let do_handshake = move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
        Ok((
            make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 1),
            KePhaseTimings::default(),
        ))
    };

    let mut generations = Vec::with_capacity(3);
    for _ in 0..3 {
        let (ctx, _) = table
            .checkout_with(&spec, Duration::from_secs(5), 4, &do_handshake)
            .unwrap_or_else(|e| panic!("checkout failed: {e:?}"));
        generations.push(ctx.session_generation);
    }
    // All three must be distinct: each handshake mints its own
    // generation via `next_session_generation()`, and each
    // checkout drains the just-installed jar of its single cookie,
    // forcing the next call to re-handshake.
    assert_eq!(generations.len(), 3);
    assert_ne!(generations[0], generations[1]);
    assert_ne!(generations[1], generations[2]);
    assert_ne!(generations[0], generations[2]);
}

// ------------------------------------------------------------------
// Trust-anchor diagnostics + strict-mode tests (nts-21j, 3.0.0).
//
// Pin the public conversions between `TrustMode`/`TrustBackend` and
// their protocol-layer mirrors, the `NtsError` mapping for the new
// `TrustBackendUnavailable` variant, and the `NtsClient` round-trip
// of `trust_mode()` so a future refactor of either layer surfaces
// here rather than in a downstream consumer's exhaustive `switch`.
// ------------------------------------------------------------------

/// Acceptance criterion 4 (default trust mode is unchanged): a
/// freshly-constructed `NtsClient` reports
/// `TrustMode::PlatformWithFallback`. The default singleton path
/// surfaced by `nts_query` / `nts_warm_cookies` likewise reaches
/// `establish_session` with this mode (verified by the live
/// integration tests further up).
#[test]
fn nts_client_default_trust_mode_is_platform_with_fallback() {
    let client = NtsClient::new();
    assert_eq!(client.trust_mode(), TrustMode::PlatformWithFallback);
}

/// Acceptance criterion 3 (strict mode is opt-in): a client minted
/// with `TrustMode::PlatformOnly` round-trips that mode through
/// `trust_mode()` and `is_default == false`, so subsequent
/// handshakes reach `build_tls_config` with the strict policy and
/// do not contribute to the singleton-path observable surfaced by
/// `nts_trust_status`.
#[test]
fn nts_client_with_trust_mode_round_trips_strict() {
    let client = NtsClient::with_trust_mode(TrustMode::PlatformOnly);
    assert_eq!(client.trust_mode(), TrustMode::PlatformOnly);
    assert!(!client.is_default);
}

/// Pin the `KeError::TrustBackendUnavailable -> NtsError::TrustBackendUnavailable`
/// mapping. The failure shape is the load-bearing observable for
/// strict-mode callers — collapsing it onto `KeProtocol` would
/// re-introduce the silent-downgrade hazard the strict mode is
/// meant to surface as a typed error.
#[test]
fn ke_error_trust_backend_unavailable_maps_to_typed_nts_error() {
    let ke_err = KeError::TrustBackendUnavailable("synthetic test failure".into());
    let nts_err: NtsError = ke_err.into();
    match nts_err {
        NtsError::TrustBackendUnavailable(msg) => {
            assert!(
                msg.contains("synthetic test failure"),
                "diagnostic should be preserved verbatim, got {msg:?}",
            );
        }
        other => panic!("expected TrustBackendUnavailable, got {other:?}"),
    }
}

/// Pin the `From` round-trips between the public `TrustMode` /
/// `TrustBackend` enums and their protocol-layer mirrors. The
/// `From` chain is the only thing keeping `establish_session`'s
/// trust-mode plumbing from silently dropping a variant on
/// either end of the boundary.
#[test]
#[expect(
    clippy::match_same_arms,
    reason = "the per-pair arms are intentionally enumerated rather than \
              collapsed via `|`: each (input, output) pair pins one \
              conversion as a regression target so a future variant added \
              on either side surfaces as a missing arm at compile time, \
              not as silent passthrough on the wildcard arm"
)]
fn trust_mode_and_backend_conversions_are_total() {
    // TrustMode -> KeTrustMode
    for m in [TrustMode::PlatformWithFallback, TrustMode::PlatformOnly] {
        let ke: crate::nts::ke::KeTrustMode = m.into();
        match (m, ke) {
            (
                TrustMode::PlatformWithFallback,
                crate::nts::ke::KeTrustMode::PlatformWithFallback,
            ) => {}
            (TrustMode::PlatformOnly, crate::nts::ke::KeTrustMode::PlatformOnly) => {}
            _ => panic!("TrustMode -> KeTrustMode mapping diverged"),
        }
    }
    // KeTrustBackend -> TrustBackend
    for b in [
        crate::nts::ke::KeTrustBackend::Platform,
        crate::nts::ke::KeTrustBackend::PlatformWithHybridFallback,
        crate::nts::ke::KeTrustBackend::WebpkiRoots,
    ] {
        let public: TrustBackend = b.into();
        match (b, public) {
            (crate::nts::ke::KeTrustBackend::Platform, TrustBackend::Platform) => {}
            (
                crate::nts::ke::KeTrustBackend::PlatformWithHybridFallback,
                TrustBackend::PlatformWithHybridFallback,
            ) => {}
            (crate::nts::ke::KeTrustBackend::WebpkiRoots, TrustBackend::WebpkiRoots) => {}
            _ => panic!("KeTrustBackend -> TrustBackend mapping diverged"),
        }
    }
}

/// `nts_trust_status()` must be safe to call with no prior
/// handshake (process just started, or all queries went through
/// caller-minted clients). Snapshot fields land at their
/// documented "no signal yet" values rather than panicking on a
/// missing observation.
#[test]
fn nts_trust_status_snapshot_is_safe_with_no_handshake() {
    let status = nts_trust_status();
    // android_platform_init_succeeded is always false off-Android;
    // on Android the test harness does not invoke the JNI bootstrap
    // either, so the same assertion holds.
    assert!(!status.android_platform_init_succeeded);
    // The cumulative counters are `Relaxed` and global; we cannot
    // assert == 0 because earlier tests in this process may have
    // exercised the Android-only code path or the singleton-handshake
    // recording path. Assert weak monotonicity: calling snapshot
    // twice shows each per-counter second value is >= the first.
    let second = nts_trust_status();
    assert!(second.android_hybrid_fallback_count >= status.android_hybrid_fallback_count);
    assert!(second.default_backend_platform_count >= status.default_backend_platform_count);
    assert!(second.default_backend_hybrid_count >= status.default_backend_hybrid_count);
    assert!(second.default_backend_webpki_count >= status.default_backend_webpki_count);
}

/// Cached-session checkouts must surface the original handshake's
/// `trust_backend` via `QueryContext`, mirroring how
/// `phase_timings` is zeroed-but-present on the cache-hit path.
/// Without this the per-query `NtsTimeSample::trust_backend`
/// attribution would degrade on every cached query and callers
/// would not be able to round-trip provenance through their
/// observability layer.
#[test]
fn checkout_cache_hit_preserves_session_trust_backend() {
    let table = SessionTable::new();
    let spec = NtsServerSpec {
        host: "trust-backend-cache-hit.test".into(),
        port: 4460,
    };
    // Pre-install a session whose trust_backend is
    // `PlatformWithHybridFallback` (a non-default value, so a
    // regression that hard-codes Platform on the cache-hit path
    // surfaces as a value mismatch).
    let mut session = make_test_session_with_cookies(
        "trust-backend-cache-hit.test",
        4460,
        next_session_generation(),
        4,
    );
    session.trust_backend = TrustBackend::PlatformWithHybridFallback;
    table.install(&spec, session);
    let (ctx, _) = table
        .checkout(
            &spec,
            Duration::from_secs(5),
            4,
            TrustMode::PlatformWithFallback,
        )
        .expect("cache hit");
    assert_eq!(ctx.trust_backend, TrustBackend::PlatformWithHybridFallback);
}

/// `nts-upv` acceptance criterion: N concurrent
/// `warm_cookies_with` calls against the same `host:port`
/// collapse onto exactly ONE KE handshake. Pre-4.0.0
/// `nts_warm_cookies` called `establish_session` directly,
/// bypassing the singleflight machinery and producing N parallel
/// handshakes. Same `BoundedRelease` + `await_singleflight_state`
/// test pattern as `checkout_collapses_concurrent_cold_queries_*`
/// so the deterministic-release shape stays uniform across the
/// two singleflight entry points.
#[test]
fn warm_cookies_collapses_concurrent_forced_refreshes_onto_one_handshake() {
    const N: usize = 6;
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "warm-singleflight-collapse.test".into(),
        port: 4460,
    };
    let handshake_count = Arc::new(AtomicUsize::new(0));
    let release = BoundedRelease::new();
    let release_handle = release.handle();
    // Synthetic non-default KePhaseTimings sentinel returned by
    // the test handshake closure. The leader surfaces these
    // verbatim from `do_handshake`; waiters surface
    // `KePhaseTimings::default()` because they did not perform KE
    // work themselves. The two are observationally
    // distinguishable, so the test can assert exactly 1 leader
    // and N-1 waiters by inspecting `phase_timings` alongside
    // counting handshake-closure invocations.
    let leader_timings = KePhaseTimings {
        dns_micros: 11,
        connect_micros: 22,
        tls_handshake_micros: 33,
        ke_record_io_micros: 44,
    };
    let do_handshake = {
        let handshake_count = handshake_count.clone();
        move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            handshake_count.fetch_add(1, Ordering::SeqCst);
            release_handle
                .wait_release(Duration::from_secs(10))
                .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
            Ok((
                make_test_session_with_cookies(&spec.host, 123, next_session_generation(), N + 2),
                leader_timings,
            ))
        }
    };

    let handles: Vec<_> = (0..N)
        .map(|_| {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
            })
        })
        .collect();

    let key = session_key(&spec);
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
        slot.is_some_and(|s| Arc::strong_count(s) == N + 1)
    });
    release.release();

    let mut leader_count = 0;
    let mut waiter_count = 0;
    for h in handles {
        let (count, timings, _backend) = h
            .join()
            .expect("warm_cookies thread panicked")
            .expect("warm_cookies returned Err");
        assert!(
            count > 0,
            "every concurrent warm reported a non-zero cookie count",
        );
        if timings == KePhaseTimings::default() {
            waiter_count += 1;
        } else {
            assert_eq!(
                timings, leader_timings,
                "leader surfaced unexpected KePhaseTimings",
            );
            leader_count += 1;
        }
    }
    assert_eq!(
        leader_count, 1,
        "exactly one caller observed leader timings"
    );
    assert_eq!(
        waiter_count,
        N - 1,
        "the remaining N-1 callers observed waiter (default) timings",
    );
    assert_eq!(
        handshake_count.load(Ordering::SeqCst),
        1,
        "exactly one handshake ran across {N} concurrent warm_cookies",
    );
}

/// Singleflight failure-fan-out semantic: when the leader's
/// handshake fails, every waiter receives a cloned `NtsError`
/// with the same variant/payload as the leader. Mirrors
/// `checkout_propagates_leader_failure_to_every_waiter`.
#[test]
fn warm_cookies_propagates_leader_failure_to_every_waiter() {
    const N: usize = 4;
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "warm-singleflight-leader-fail.test".into(),
        port: 4460,
    };
    let handshake_count = Arc::new(AtomicUsize::new(0));
    let release = BoundedRelease::new();
    let release_handle = release.handle();
    let do_handshake = {
        let handshake_count = handshake_count.clone();
        move |_: &NtsServerSpec, _t: Duration, _c: usize| {
            handshake_count.fetch_add(1, Ordering::SeqCst);
            release_handle
                .wait_release(Duration::from_secs(10))
                .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
            Err(NtsError::KeProtocol {
                message: "synthetic warm-leader-failure for singleflight test".into(),
                trust_backend: None,
            })
        }
    };

    let handles: Vec<_> = (0..N)
        .map(|_| {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
            })
        })
        .collect();

    let key = session_key(&spec);
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
        slot.is_some_and(|s| Arc::strong_count(s) == N + 1)
    });
    release.release();

    for h in handles {
        match h.join().expect("thread panicked") {
            Err(NtsError::KeProtocol { message: msg, .. }) => {
                assert_eq!(msg, "synthetic warm-leader-failure for singleflight test");
            }
            Err(other) => panic!("expected KeProtocol; got {other:?}"),
            Ok(_) => panic!("warm_cookies returned Ok despite leader failure"),
        }
    }
    assert_eq!(
        handshake_count.load(Ordering::SeqCst),
        1,
        "waiters did not silently retry the failed handshake",
    );
}

/// Cross-API singleflight collapse: a concurrent `checkout_with`
/// (NTP-query path) and `warm_cookies_with` (forced-refresh path)
/// against the same `host:port` collapse onto exactly ONE KE
/// handshake. Both APIs share the same `inflight` registry keyed
/// off `session_key(spec)`, so whichever caller arrives first
/// becomes the leader and the other parks on the same slot.
/// This is the property that lets a UI binding both a
/// "refresh time" button (warm) and an underlying poll (query)
/// keep its KE-wire footprint bounded under rapid taps.
#[test]
fn warm_cookies_collapses_with_concurrent_query_against_same_host() {
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "warm-and-query-singleflight-collapse.test".into(),
        port: 4460,
    };
    let handshake_count = Arc::new(AtomicUsize::new(0));
    let release = BoundedRelease::new();
    let release_handle = release.handle();
    let do_handshake = {
        let handshake_count = handshake_count.clone();
        move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            handshake_count.fetch_add(1, Ordering::SeqCst);
            release_handle
                .wait_release(Duration::from_secs(10))
                .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
            Ok((
                make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
                KePhaseTimings::default(),
            ))
        }
    };

    let warm = {
        let table = table.clone();
        let spec = spec.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
        })
    };
    let query = {
        let table = table.clone();
        let spec = spec.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table
                .checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                .map(|(ctx, _)| ctx)
        })
    };

    // Wait until both threads have registered against the same
    // inflight slot (one as leader, one as waiter); strong count
    // = 1 (inflight map) + 1 (LeaderGuard) + 1 (waiter Arc clone)
    // = 3, regardless of which API arrived first.
    let key = session_key(&spec);
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
        slot.is_some_and(|s| Arc::strong_count(s) == 3)
    });
    release.release();

    let warm_outcome = warm
        .join()
        .expect("warm thread panicked")
        .expect("warm_cookies returned Err");
    let query_outcome = query
        .join()
        .expect("query thread panicked")
        .expect("checkout returned Err");
    assert!(warm_outcome.0 > 0, "warm reported a non-zero cookie count");
    assert!(
        !query_outcome.cookie.is_empty(),
        "query returned a non-empty cookie",
    );
    assert_eq!(
        handshake_count.load(Ordering::SeqCst),
        1,
        "concurrent warm + query collapsed onto one handshake",
    );
}

/// Contract test for `NtsWarmCookiesOutcome.fresh_cookies` /
/// `NtsTimeSample.freshCookies` ("Number of fresh cookies the
/// server delivered with the KE response"): a `warm_cookies_with`
/// waiter must surface the leader's *harvested* cookie count even
/// when a concurrent `checkout_with` leader has popped one
/// cookie out of the freshly installed jar before the warm
/// waiter wakes.
///
/// Forces query-leader-first ordering by spawning the query
/// thread, awaiting its `LeaderGuard` registration via the
/// `Arc::strong_count == 2` rendezvous, then spawning the warm
/// waiter. The leader's `checkout_with` install-then-pop happens
/// under the `map` lock and *before* `HandshakeSlot::complete`
/// publishes the slot result, so by the time the warm waiter
/// wakes the cache holds `delivered - 1` cookies — observably
/// fewer than the contract value. Pre-fix code (warm waiter
/// snapshots `cookies_remaining()` from the cache) reports
/// `delivered - 1`; post-fix code (warm waiter reads
/// `HandshakeSlotOk.fresh_cookies` from the slot payload)
/// reports `delivered`.
#[test]
fn warm_cookies_waiter_reports_delivered_count_when_query_leader_pops_first() {
    const DELIVERED: usize = 4;
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "warm-waiter-vs-query-leader-pop.test".into(),
        port: 4460,
    };
    let handshake_count = Arc::new(AtomicUsize::new(0));
    let release = BoundedRelease::new();
    let release_handle = release.handle();
    let do_handshake = {
        let handshake_count = handshake_count.clone();
        move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            handshake_count.fetch_add(1, Ordering::SeqCst);
            release_handle
                .wait_release(Duration::from_secs(10))
                .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
            Ok((
                make_test_session_with_cookies(
                    &spec.host,
                    123,
                    next_session_generation(),
                    DELIVERED,
                ),
                KePhaseTimings::default(),
            ))
        }
    };

    // Phase 1: spawn query, wait for it to register as leader.
    // Strong count = 1 (inflight map) + 1 (LeaderGuard) = 2.
    let key = session_key(&spec);
    let query = {
        let table = table.clone();
        let spec = spec.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table
                .checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                .map(|(ctx, _)| ctx)
        })
    };
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
        slot.is_some_and(|s| Arc::strong_count(s) == 2)
    });

    // Phase 2: spawn warm waiter. Strong count rises to 3.
    let warm = {
        let table = table.clone();
        let spec = spec.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
        })
    };
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
        slot.is_some_and(|s| Arc::strong_count(s) == 3)
    });

    // Phase 3: release the leader. It installs the session,
    // pops one cookie under the `map` lock, then publishes the
    // slot result. The warm waiter wakes after the pop has
    // already landed in the cache.
    release.release();

    let warm_outcome = warm
        .join()
        .expect("warm thread panicked")
        .expect("warm_cookies returned Err");
    let query_outcome = query
        .join()
        .expect("query thread panicked")
        .expect("checkout returned Err");

    assert!(
        !query_outcome.cookie.is_empty(),
        "query leader returned a non-empty cookie",
    );
    assert_eq!(
        warm_outcome.0, DELIVERED as u32,
        "warm waiter reported the leader's harvested count, \
         not a post-pop snapshot of the cache",
    );
    assert_eq!(
        handshake_count.load(Ordering::SeqCst),
        1,
        "query leader + warm waiter collapsed onto one handshake",
    );
}

/// Singleflight is keyed by `session_key(spec)`, so concurrent
/// `warm_cookies_with` calls against *different* hosts continue to
/// run their handshakes in parallel. Mirrors
/// `checkout_does_not_serialize_handshakes_across_distinct_hosts`.
#[test]
fn warm_cookies_does_not_serialize_across_distinct_hosts() {
    let table = Arc::new(SessionTable::new());
    let spec_a = NtsServerSpec {
        host: "warm-host-a.test".into(),
        port: 4460,
    };
    let spec_b = NtsServerSpec {
        host: "warm-host-b.test".into(),
        port: 4460,
    };
    // Bounded rendezvous: each leader bumps `arrived_count`, then
    // polls until it reaches 2. If singleflight ever regresses
    // and serialises the two warms, the second leader never
    // arrives, the first leader's poll deadline elapses, and the
    // closure returns a synthetic `Internal` so the test fails
    // fast instead of hanging the CI job.
    let arrived_count = Arc::new(AtomicUsize::new(0));
    let do_handshake = {
        let arrived_count = arrived_count.clone();
        move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            arrived_count.fetch_add(1, Ordering::SeqCst);
            let deadline = Instant::now() + Duration::from_secs(2);
            while arrived_count.load(Ordering::SeqCst) < 2 {
                if Instant::now() >= deadline {
                    return Err(NtsError::Internal(
                        "second handshake never arrived; singleflight is serialising hosts".into(),
                    ));
                }
                thread::sleep(Duration::from_millis(1));
            }
            Ok((
                make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
                KePhaseTimings::default(),
            ))
        }
    };

    let warm_a = {
        let table = table.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table.warm_cookies_with(&spec_a, Duration::from_secs(10), 4, &do_handshake)
        })
    };
    let warm_b = {
        let table = table.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table.warm_cookies_with(&spec_b, Duration::from_secs(10), 4, &do_handshake)
        })
    };

    warm_a
        .join()
        .expect("warm_a panicked")
        .expect("warm_a returned Err — singleflight is serialising distinct hosts");
    warm_b
        .join()
        .expect("warm_b panicked")
        .expect("warm_b returned Err — singleflight is serialising distinct hosts");
}

/// Waiter timeout: when the leader's handshake outlasts the
/// waiter's per-call deadline, the waiter must surface
/// `Timeout(KeRecordIo)` — same `phase` taxonomy
/// `checkout_with`'s waiter path uses for the same shape.
/// Mirror of `checkout_waiter_returns_timeout_when_leader_outlasts_deadline`.
#[test]
fn warm_cookies_waiter_returns_timeout_when_leader_outlasts_deadline() {
    let table = Arc::new(SessionTable::new());
    let spec = NtsServerSpec {
        host: "warm-singleflight-waiter-timeout.test".into(),
        port: 4460,
    };
    let leader_release = BoundedRelease::new();
    let leader_release_handle = leader_release.handle();
    let do_handshake = move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
        leader_release_handle
            .wait_release(Duration::from_secs(10))
            .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
        Ok((
            make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
            KePhaseTimings::default(),
        ))
    };

    let leader = {
        let table = table.clone();
        let spec = spec.clone();
        let do_handshake = do_handshake.clone();
        thread::spawn(move || {
            table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
        })
    };

    // Wait until the leader has registered an inflight slot
    // before spawning the waiter, otherwise the waiter could
    // become the leader itself and run a handshake.
    let key = session_key(&spec);
    await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| slot.is_some());

    let waiter_started = Instant::now();
    let waiter_outcome = table.warm_cookies_with(
        &spec,
        Duration::from_millis(100),
        4,
        &|_: &NtsServerSpec, _t: Duration, _c: usize| {
            panic!("waiter should never run a handshake; it must park on the leader's slot")
        },
    );
    let waiter_elapsed = waiter_started.elapsed();

    match waiter_outcome {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::KeRecordIo,
            trust_backend: None,
        }) => {}
        Err(other) => panic!("expected Timeout(KeRecordIo); got {other:?}"),
        Ok(_) => panic!("waiter returned Ok despite a parked leader"),
    }
    assert!(
        waiter_elapsed >= Duration::from_millis(100),
        "waiter returned before its 100ms budget elapsed: {waiter_elapsed:?}",
    );
    assert!(
        waiter_elapsed < Duration::from_millis(2_000),
        "waiter overshot its budget by >2s; deadline plumbing is broken: {waiter_elapsed:?}",
    );

    leader_release.release();
    if let Err(e) = leader.join().expect("leader thread panicked") {
        panic!("leader warm_cookies failed: {e:?}");
    }
}

/// Pre-handshake budget exhaustion on a (re-)elected leader: when
/// a thread enters `warm_cookies_with` with `started.elapsed()`
/// already exceeding `timeout`, the leader path must surface
/// `Timeout(DnsTimeout)` *before* invoking `do_handshake`, so a
/// caller's documented per-call wall-clock budget cannot be
/// silently extended by a re-leader's fresh `timeout`-long
/// window. The phase tag is `DnsTimeout` (not `KeRecordIo`)
/// because no record I/O has happened on this thread yet — the
/// next phase that *would* have run is DNS. Same taxonomy as
/// [`UdpDeadline::remaining_or_timeout`] applies pre-DNS on the
/// UDP path. Provenance: bd nts-r54.
///
/// Driven directly via a `Duration::ZERO` budget on a fresh
/// table so the leader's `checked_sub` falls into the budget-
/// exhausted arm on the very first iteration: with `timeout =
/// ZERO`, the subtraction returns `None` whenever
/// `started.elapsed() > 0`, and even on the boundary case
/// (`elapsed = 0`) returns `Some(0)` which the
/// `Some(d) if !d.is_zero()` guard rejects, so the `_` arm
/// fires either way. The handshake closure asserts it is never
/// invoked.
#[test]
fn warm_cookies_leader_budget_exhausted_before_handshake_returns_dns_timeout() {
    let table = SessionTable::new();
    let spec = NtsServerSpec {
        host: "warm-singleflight-budget-exhausted.test".into(),
        port: 4460,
    };
    let outcome = table.warm_cookies_with(
        &spec,
        Duration::ZERO,
        4,
        &|_: &NtsServerSpec, _t: Duration, _c: usize| {
            panic!("do_handshake must not be invoked when the per-call budget is exhausted")
        },
    );
    match outcome {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::DnsTimeout,
            trust_backend: None,
        }) => {}
        Err(other) => panic!("expected Timeout(DnsTimeout); got {other:?}"),
        Ok(_) => panic!("warm_cookies returned Ok despite an exhausted budget"),
    }
    // The inflight slot must have been cleaned up by the
    // LeaderGuard so a follow-up call against the same key can
    // become a fresh leader; otherwise a single budget-exhaustion
    // event would permanently strand future warms behind a
    // slot whose result is `Timeout`.
    let key = session_key(&spec);
    let g = table
        .inflight
        .lock()
        .expect("inflight singleflight map poisoned");
    assert!(
        !g.contains_key(&key),
        "inflight slot leaked after budget-exhaustion path",
    );
}

/// Symmetric counterpart for `checkout_with`: pre-handshake
/// budget exhaustion on a (re-)elected leader must surface
/// `Timeout(DnsTimeout)`, not `KeRecordIo`. The bd ticket
/// (nts-r54) describes the realistic scenario as a thread that
/// previously parked as a waiter, woke when the leader signalled,
/// found the cookie pool drained by another concurrent waker,
/// fell through to phase B again, elected itself as the next
/// leader, and then found the call-wide budget already
/// exhausted. The bug it pins is in a single line — the
/// `checked_sub` arm at the leader-budget check — so this test
/// drives that line directly via a `Duration::ZERO` budget on a
/// fresh table. With `timeout = ZERO`, the subtraction returns
/// `None` whenever `started.elapsed() > 0`, and even on the
/// boundary case (`elapsed = 0`) returns `Some(0)` which the
/// `Some(d) if !d.is_zero()` guard rejects, so the budget-
/// exhausted `_` arm fires on the very first iteration either
/// way. The realistic re-leader scenario reaches the same
/// `_` arm via a different multi-thread path; the underlying
/// bug being pinned is the same.
/// Mirrors `warm_cookies_leader_budget_exhausted_before_handshake_returns_dns_timeout`.
/// Provenance: bd nts-r54.
#[test]
fn checkout_leader_budget_exhausted_before_handshake_returns_dns_timeout() {
    let table = SessionTable::new();
    let spec = NtsServerSpec {
        host: "checkout-singleflight-budget-exhausted.test".into(),
        port: 4460,
    };
    let outcome = table.checkout_with(
        &spec,
        Duration::ZERO,
        4,
        &|_: &NtsServerSpec, _t: Duration, _c: usize| {
            panic!("do_handshake must not be invoked when the per-call budget is exhausted")
        },
    );
    match outcome {
        Err(NtsError::Timeout {
            phase: TimeoutPhase::DnsTimeout,
            trust_backend: None,
        }) => {}
        Err(other) => panic!("expected Timeout(DnsTimeout); got {other:?}"),
        Ok(_) => panic!("checkout returned Ok despite an exhausted budget"),
    }
    // Same inflight-slot cleanup invariant as the warm_cookies
    // counterpart: a single budget-exhaustion event must not
    // strand future checkouts behind a stale slot.
    let key = session_key(&spec);
    let g = table
        .inflight
        .lock()
        .expect("inflight singleflight map poisoned");
    assert!(
        !g.contains_key(&key),
        "inflight slot leaked after checkout budget-exhaustion path",
    );
}

/// Defensive shape: a handshake that returns a `Session` with
/// zero cookies must surface `NtsError::NoCookies` from the
/// leader path — same shape `checkout_with` uses for the same
/// case. A regression that installed the empty session would
/// cause every concurrent waiter to fall through to a misleading
/// "warm succeeded with 0 cookies" outcome (`fresh_cookies: 0`),
/// which the pre-handshake guard exists to prevent.
#[test]
fn warm_cookies_leader_refuses_zero_cookie_session() {
    let table = SessionTable::new();
    let spec = NtsServerSpec {
        host: "warm-singleflight-zero-cookie.test".into(),
        port: 4460,
    };
    let do_handshake = |spec: &NtsServerSpec, _t: Duration, _c: usize| {
        // `make_test_session` returns a session whose `jar` has
        // no cookies in it (cookie_count == 0); install would
        // otherwise have written a useless session into the map.
        let session = make_test_session(&spec.host, 123, next_session_generation());
        Ok((session, KePhaseTimings::default()))
    };
    match table.warm_cookies_with(&spec, Duration::from_secs(5), 4, &do_handshake) {
        Err(NtsError::NoCookies {
            trust_backend: Some(_),
        }) => {}
        Err(other) => panic!("expected NoCookies(Some(_)); got {other:?}"),
        Ok((count, _, _)) => {
            panic!("warm_cookies returned Ok with count={count} despite a 0-cookie handshake",)
        }
    }
    // The leader must NOT have installed the empty session, so
    // a subsequent call sees an empty cache and re-elects.
    let key = session_key(&spec);
    let g = table.map.lock().expect("session table poisoned");
    assert!(
        !g.contains_key(&key),
        "leader installed a 0-cookie session despite the defensive refusal",
    );
}

/// Round-trip every `TrustBackend` variant through the `From`
/// conversion to `InternalTrustBackend` (used by the trust-state
/// recording path) and back, pinning the bidirectional mapping. A
/// future Rust-side variant addition surfaces as a non-compiling
/// match arm in *both* `From` impls; this test additionally pins
/// the invariant that the round-trip preserves identity for every
/// listed variant rather than collapsing two onto a single internal
/// counterpart.
#[test]
fn trust_backend_round_trips_through_internal() {
    for variant in [
        TrustBackend::Platform,
        TrustBackend::PlatformWithHybridFallback,
        TrustBackend::WebpkiRoots,
    ] {
        let internal: crate::nts::trust_state::InternalTrustBackend = variant.into();
        let back: TrustBackend = internal.into();
        assert_eq!(back, variant, "variant {variant:?} did not round-trip");
    }
}

/// `KeTrustBackend` (the KE-layer-internal taxonomy) maps onto
/// `TrustBackend` (the public-API enum that crosses the FRB
/// boundary). Pin every variant so a Rust-side rename in `nts::ke`
/// surfaces as a non-compiling arm here rather than as a silent
/// re-attribution at the consumer.
#[test]
fn ke_trust_backend_maps_to_public_trust_backend() {
    use crate::nts::ke::KeTrustBackend;
    for (ke_variant, public_variant) in [
        (KeTrustBackend::Platform, TrustBackend::Platform),
        (
            KeTrustBackend::PlatformWithHybridFallback,
            TrustBackend::PlatformWithHybridFallback,
        ),
        (KeTrustBackend::WebpkiRoots, TrustBackend::WebpkiRoots),
    ] {
        let mapped: TrustBackend = ke_variant.into();
        assert_eq!(mapped, public_variant, "{ke_variant:?} did not map");
    }
}

/// `TrustMode` (the public-API enum) maps onto `KeTrustMode` (the
/// KE-layer-internal taxonomy). Same exhaustiveness guard as the
/// `KeTrustBackend` test above, on the inbound side of the
/// boundary.
#[test]
fn trust_mode_maps_to_ke_trust_mode() {
    use crate::nts::ke::KeTrustMode;
    for (public_variant, ke_variant) in [
        (
            TrustMode::PlatformWithFallback,
            KeTrustMode::PlatformWithFallback,
        ),
        (TrustMode::PlatformOnly, KeTrustMode::PlatformOnly),
    ] {
        let mapped: KeTrustMode = public_variant.into();
        assert_eq!(mapped, ke_variant, "{public_variant:?} did not map");
    }
}

/// `nts_trust_status()` reads the process-global `TRUST_STATE`
/// snapshot and converts the internal types onto the public DTO.
/// Tests cannot mutate the singleton without interfering with
/// every other test in the suite, so this test asserts only the
/// shape contract — that the call returns a well-formed
/// `NtsTrustStatus` whose fields agree with the singleton snapshot
/// taken at the same moment. The variant-by-variant conversion is
/// covered separately by `trust_backend_round_trips_through_internal`
/// against fresh `ProcessTrustState` instances.
#[test]
fn nts_trust_status_reads_singleton_and_converts_shape() {
    let status = nts_trust_status();
    let snap = crate::nts::trust_state::TRUST_STATE.snapshot();
    // `default_client_backend` may be `None` if no singleton
    // handshake has run in this process yet; the contract is
    // that *if* the snapshot says `Some`, the public DTO carries
    // the matching `TrustBackend` variant.
    match (snap.default_backend, status.default_client_backend) {
        (None, None) => {}
        (Some(internal), Some(public)) => {
            let mapped: TrustBackend = internal.into();
            assert_eq!(public, mapped);
        }
        other => panic!(
            "default_backend Option-shape mismatch between snapshot \
             and DTO: {other:?}"
        ),
    }
    assert_eq!(
        status.default_backend_platform_count,
        snap.default_backend_platform_count,
    );
    assert_eq!(
        status.default_backend_hybrid_count,
        snap.default_backend_hybrid_count,
    );
    assert_eq!(
        status.default_backend_webpki_count,
        snap.default_backend_webpki_count,
    );
    assert_eq!(
        status.android_platform_init_succeeded,
        snap.android_platform_init_succeeded,
    );
    assert_eq!(
        status.android_hybrid_fallback_count,
        snap.android_hybrid_fallback_count,
    );
}

/// `NtsClient::with_trust_mode` plumbs the requested mode onto the
/// constructed handle and the `trust_mode()` accessor reads it
/// back. `NtsClient::new` is the documented equivalent of
/// `with_trust_mode(PlatformWithFallback)`. Both invariants are
/// what the Dart-side wrapper relies on to round-trip the
/// caller's policy through the FRB boundary.
#[test]
fn nts_client_trust_mode_round_trips_construction_choice() {
    assert_eq!(
        NtsClient::new().trust_mode(),
        TrustMode::PlatformWithFallback
    );
    assert_eq!(
        NtsClient::with_trust_mode(TrustMode::PlatformWithFallback).trust_mode(),
        TrustMode::PlatformWithFallback,
    );
    assert_eq!(
        NtsClient::with_trust_mode(TrustMode::PlatformOnly).trust_mode(),
        TrustMode::PlatformOnly,
    );
}

/// Pins the RFC 8915 §5.6 unpredictability property at the
/// *production* UID-generation site by driving the same module-
/// scope helper [`super::fresh_request_uid_and_nonce`] that
/// `nts_query_inner` uses to mint per-request UIDs and nonces.
///
/// Anchoring the assertion to the helper (rather than calling
/// `getrandom::fill` directly here in the test) means a
/// regression where `nts_query_inner` stops calling the helper —
/// or where the helper itself is rewritten to reuse a cached
/// UID, swap in constant bytes during a debugging session, or
/// pull from a broken RNG — would actually be caught by this
/// test. A test that reimplemented the `getrandom`-then-pack-
/// into-`ClientRequest` flow inline would *not* catch any of
/// those shapes, because the production code path would have
/// drifted out from under the test.
///
/// To keep the production code path honest end-to-end the test
/// also serialises each UID into a `ClientRequest` and runs it
/// through `build_client_request`, then parses the resulting
/// wire bytes back to recover the on-wire UID extension and
/// asserts uniqueness on those bodies. Catches a hypothetical
/// regression where the helper returns distinct UIDs but
/// `build_client_request` pins them to a constant on the wire
/// (today the production wire encoding is a verbatim copy of
/// `req.unique_id`, but the test holds independently of that).
///
/// Why this lives in `api::nts::tests` rather than
/// `nts::ntp::tests`: `nts::ntp` is intentionally
/// `getrandom`/`rand`-free (the module-level rustdoc says "all
/// randomness is supplied by the caller"); the production UID-
/// generation call site is in `nts_query_inner` here in
/// `api::nts`, and so is the helper that funnels its randomness.
///
/// 100 iterations catches the gross-brokenness shape; the
/// birthday bound at 256 bits of UID entropy makes a real-RNG
/// collision astronomically unlikely, so this test does not
/// flake on healthy `getrandom`.
#[test]
fn consecutive_request_uids_from_helper_are_distinct() {
    use crate::nts::ntp::{
        build_client_request, ext_type, parse_extensions, ClientRequest, HEADER_LEN,
    };
    use std::collections::HashSet;

    let c2s_key = AeadKey::from_keying_material(15, &[0x11u8; 32])
        .expect("c2s key constructs from canonical SIV-CMAC-256 material");
    let nonce_len = c2s_key.nonce_len();
    let cookie = vec![0x55u8; 64];

    let mut seen = HashSet::with_capacity(100);
    for iteration in 0..100 {
        // Production helper: same call site as `nts_query_inner`.
        let (uid, nonce) = super::fresh_request_uid_and_nonce(nonce_len)
            .unwrap_or_else(|e| panic!("iteration {iteration}: helper failed: {e:?}"));

        let req = ClientRequest {
            unique_id: uid.to_vec(),
            cookie: zeroize::Zeroizing::new(cookie.clone()),
            placeholder_count: 0,
            nonce,
            transmit_timestamp: 0,
        };
        let packet = build_client_request(&req, &c2s_key)
            .unwrap_or_else(|e| panic!("iteration {iteration}: build_client_request: {e:?}"));
        let extensions = parse_extensions(&packet[HEADER_LEN..])
            .unwrap_or_else(|e| panic!("iteration {iteration}: parse_extensions: {e:?}"));
        let on_wire_uid = extensions
            .iter()
            .find(|ext| ext.field_type == ext_type::UNIQUE_IDENTIFIER)
            .unwrap_or_else(|| panic!("iteration {iteration}: UID extension missing on wire"))
            .body
            .clone();
        assert_eq!(
            on_wire_uid.len(),
            UID_LEN,
            "iteration {iteration}: on-wire UID length is not {UID_LEN}",
        );
        assert!(
            seen.insert(on_wire_uid.clone()),
            "iteration {iteration}: UID collision against earlier iteration ({on_wire_uid:02x?})",
        );
    }
    assert_eq!(
        seen.len(),
        100,
        "expected 100 distinct UIDs, got {}",
        seen.len()
    );
}

/// Regression tests for the [`super::lock_recover`] poisoning-
/// recovery helper. Every `.lock().expect(…)` site in the
/// `api::nts` module has been swept to `lock_recover(&...)` so a
/// panic on any thread holding any of the module's mutexes does
/// not turn into a permanent crash-on-use mode for the client
/// across the FRB boundary. See the helper's rustdoc for the
/// safety argument.
mod lock_recover {
    use super::super::lock_recover;
    use std::panic;
    use std::sync::{Arc, Mutex};
    use std::thread;

    /// Poisons a `Mutex` by panicking from a thread that holds the
    /// lock, then asserts the recovery helper succeeds where a
    /// plain `Mutex::lock` would propagate the `PoisonError`. The
    /// `catch_unwind`-style join is the canonical idiom for
    /// observing a poisoned mutex from a test harness without
    /// taking the harness down.
    #[test]
    fn lock_recover_returns_inner_guard_after_poisoning() {
        let m = Arc::new(Mutex::new(42u32));
        let m2 = Arc::clone(&m);

        // A no-op hook avoids stderr noise when the worker thread
        // panics during this test; restored on drop so neighbouring
        // tests are unaffected.
        let prev_hook = panic::take_hook();
        panic::set_hook(Box::new(|_| {}));
        let join_result = thread::spawn(move || {
            let _g = m2.lock().expect("first lock must succeed");
            panic!("deliberate panic to poison the mutex");
        })
        .join();
        panic::set_hook(prev_hook);

        // The worker thread panicked: the join returns `Err` and
        // the mutex is now poisoned.
        assert!(join_result.is_err(), "worker thread should have panicked");
        assert!(
            m.lock().is_err(),
            "Mutex must be poisoned after the worker thread panicked under the lock",
        );

        // `lock_recover` extracts the inner guard regardless of
        // the poison flag and returns the value the worker thread
        // had written before it panicked (`42`, the initial
        // value, since the worker did not mutate it).
        assert_eq!(
            *lock_recover(&m),
            42,
            "lock_recover must return the inner guard even though the mutex is poisoned",
        );
    }

    /// Mutations through `lock_recover` are visible to subsequent
    /// `lock_recover` calls, demonstrating the guard returned by
    /// the recovery path is the genuine `MutexGuard` (not a
    /// throwaway). A subsequent plain `lock()` would still report
    /// the poison flag — recovery clears the inability-to-lock
    /// failure mode, not the poison bit itself; the `is_err`
    /// assertion below pins that semantic.
    #[test]
    fn lock_recover_guard_is_writable_after_poisoning() {
        let m = Arc::new(Mutex::new(0u32));
        let m2 = Arc::clone(&m);

        let prev_hook = panic::take_hook();
        panic::set_hook(Box::new(|_| {}));
        let _ = thread::spawn(move || {
            let _g = m2.lock().expect("first lock must succeed");
            panic!("poison");
        })
        .join();
        panic::set_hook(prev_hook);

        *lock_recover(&m) = 7;
        assert_eq!(
            *lock_recover(&m),
            7,
            "lock_recover writes must be visible to subsequent lock_recover reads",
        );
        // Plain `lock()` still sees the poison flag — recovery is
        // opt-in per call site, not a global unpoison.
        assert!(
            m.lock().is_err(),
            "lock_recover does not clear the poison flag; plain lock() still reports it",
        );
    }
}

/// Compile-time pin that the cookie field on [`super::QueryContext`]
/// is wrapped in [`zeroize::Zeroizing`]. The wrapper's `Drop` impl
/// wipes the underlying `Vec<u8>` allocation when the context is
/// dropped, so a spent cookie does not linger in freed heap pages
/// between the `CookieJar` boundary and the moment
/// [`crate::nts::ntp::build_client_request`] consumes it. Mirrors
/// the analogous pin on [`crate::nts::ke::KeOutcome::c2s_key`] in
/// `ke/tests.rs`. The function-signature trick
/// (`assert_zeroizing_vec` accepts only `&Zeroizing<Vec<u8>>`)
/// makes the test fail at compile time if the field is reverted to
/// a bare `Vec<u8>`.
#[test]
fn query_context_cookie_is_zeroizing_wrapped() {
    use crate::nts::aead::AeadKey;
    use crate::nts::records::aead::AES_SIV_CMAC_256;
    use zeroize::Zeroizing;

    fn assert_zeroizing_vec(_: &Zeroizing<Vec<u8>>) {}
    let ctx = super::QueryContext {
        session_generation: 0,
        cookie: Zeroizing::new(vec![0u8; 1]),
        c2s_key: AeadKey::from_keying_material(AES_SIV_CMAC_256, &[0u8; 32]).unwrap(),
        s2c_key: AeadKey::from_keying_material(AES_SIV_CMAC_256, &[0u8; 32]).unwrap(),
        ntpv4_host: String::new(),
        ntpv4_port: 0,
        aead_id: AES_SIV_CMAC_256,
        trust_backend: super::TrustBackend::Platform,
    };
    assert_zeroizing_vec(&ctx.cookie);
}
