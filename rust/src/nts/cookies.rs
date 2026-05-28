//! Per-host NTS cookie store (RFC 8915 §6).
//!
//! Holds a bounded FIFO queue per NTS-KE host. Each `nts_query` spends one
//! cookie via [`CookieJar::take`] and ingests fresh cookies from the response
//! via [`CookieJar::put_many`]. RFC 8915 §6 mandates that cookies be used at
//! most once and that clients keep "no more than 8 unused cookies" per server
//! to bound exposure if the host's KE state is later compromised.

use std::collections::{HashMap, VecDeque};
use std::fmt;

use zeroize::Zeroizing;

/// Default per-host capacity. RFC 8915 §6 advises clients keep at most 8
/// unused cookies per server to bound exposure if KE state is later
/// compromised; this matches the cap several public deployments (e.g.
/// Cloudflare) deliver in the initial KE response. The count returned by any
/// given server is per RFC 8915 §4 a matter of server policy.
pub const DEFAULT_CAPACITY: usize = 8;

/// FIFO cookie store keyed by NTS-KE host.
///
/// Eviction is FIFO: when the queue is at capacity, the oldest cookie is
/// dropped to make room for the newest. `take` also pops from the front so
/// the oldest cookie in the pool is spent first; combined this means a cookie
/// is either spent or evicted (never reused), satisfying RFC 8915 §6.
///
/// Cookies are NTS authentication material (RFC 8915 §6): a recovered
/// cookie lets an attacker impersonate the original client to the NTS
/// server for the lifetime of the cookie's server-side AEAD key. The
/// jar therefore treats cookie bytes the way [`crate::nts::aead`]
/// treats AEAD key material: each stored cookie is held in
/// [`Zeroizing<Vec<u8>>`], so the natural drop chain
/// ([`Self::put`] overflow eviction, [`Self::clear_host`] drain,
/// [`CookieJar`] going out of scope) wipes the bytes from RAM before
/// the backing allocation is returned to the allocator. The
/// [`fmt::Debug`] implementation renders only per-host counts so
/// accidental `{:?}` formatting in logs, panic messages, or
/// diagnostic output cannot leak bytes. [`Self::take`] returns the
/// popped cookie still wrapped in [`Zeroizing`] so the bytes are
/// also wiped once the in-flight NTPv4 exchange drops the wrapper
/// after building the outbound packet — closing the last residual
/// surface where a spent cookie could linger in a freed `Vec<u8>`
/// allocation between the jar and the wire.
///
/// The records-parser → jar pipeline is itself wrapped end-to-end:
/// [`crate::nts::records::RecordKind::NewCookie`] and
/// [`crate::nts::ke::KeOutcome::cookies`] both carry
/// [`Zeroizing<Vec<u8>>`], so a panic anywhere between
/// `parse_record` and the final `put` no longer drops naked
/// `Vec<u8>` allocations (bd nts-8ey).
#[derive(Clone)]
pub struct CookieJar {
    capacity: usize,
    inner: HashMap<String, VecDeque<Zeroizing<Vec<u8>>>>,
}

/// Inner-map renderer for [`CookieJar`]'s redacted `Debug`.
/// Walks `self.0` once via `f.debug_map()` so the per-`{:?}` cost
/// is a single `Formatter` interaction rather than the
/// intermediate `HashMap<&str, usize>::collect()` the earlier
/// implementation paid. Hosts are sorted before emission so the
/// rendered output is deterministic across `HashMap` reseeds
/// (the `std::collections::HashMap` iteration order is otherwise
/// implementation-defined and varies run-to-run), which keeps
/// snapshot-style regression tests against the rendered form
/// stable. The wrapper is private to this module — it exists
/// only as a `&dyn fmt::Debug` target for `debug_struct().field`.
struct DebugCookieCounts<'a>(&'a HashMap<String, VecDeque<Zeroizing<Vec<u8>>>>);

impl fmt::Debug for DebugCookieCounts<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut hosts: Vec<&str> = self.0.keys().map(String::as_str).collect();
        hosts.sort_unstable();
        let mut m = f.debug_map();
        for host in hosts {
            // `expect` is sound: `host` came from `self.0.keys()`
            // immediately above and `self.0` is borrowed
            // immutably for the duration of this `fmt` call.
            let queue = self
                .0
                .get(host)
                .expect("host was just enumerated from self.0.keys()");
            m.entry(&host, &queue.len());
        }
        m.finish()
    }
}

impl fmt::Debug for CookieJar {
    /// Render counts only; cookies are NTS authentication material
    /// (RFC 8915 §6) and must not leak via accidental `{:?}` in logs,
    /// panic messages, or diagnostic output. Mirrors the redacted
    /// `Debug` on [`crate::nts::ke::KeOutcome`] so the same hygiene
    /// applies at both ends of the KE → cache pipeline.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CookieJar")
            .field("capacity", &self.capacity)
            .field("counts", &DebugCookieCounts(&self.inner))
            .finish()
    }
}

impl Default for CookieJar {
    fn default() -> Self {
        Self::with_capacity(DEFAULT_CAPACITY)
    }
}

impl CookieJar {
    /// Construct an empty jar with the default per-host cap.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Construct an empty jar with `capacity` cookies per host. Panics if zero.
    #[must_use]
    pub fn with_capacity(capacity: usize) -> Self {
        assert!(capacity > 0, "CookieJar capacity must be > 0");
        Self {
            capacity,
            inner: HashMap::new(),
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Insert a single cookie, evicting the oldest when at capacity.
    ///
    /// The `T: Into<Zeroizing<Vec<u8>>>` bound accepts both a plain
    /// `Vec<u8>` (wrapped on the way in via `Zeroizing::from`) and a
    /// `Zeroizing<Vec<u8>>` already produced upstream by the
    /// [`crate::nts::records`] parser or
    /// [`crate::nts::ke::KeOutcome::cookies`] (bd nts-8ey). Either
    /// way the stored value is `Zeroizing<Vec<u8>>`, so the natural
    /// drop chain wipes the bytes on every eviction path — overflow
    /// pop here, [`Self::clear_host`] drain, [`CookieJar`] going out
    /// of scope — without any further manual `zeroize()` calls.
    pub fn put<T>(&mut self, host: &str, cookie: T)
    where
        T: Into<Zeroizing<Vec<u8>>>,
    {
        let queue = self.inner.entry(host.to_owned()).or_default();
        queue.push_back(cookie.into());
        while queue.len() > self.capacity {
            // The popped `Zeroizing<Vec<u8>>` wipes its bytes when
            // it drops at the end of this iteration; no explicit
            // `zeroize()` call is needed.
            let _ = queue.pop_front();
        }
    }

    /// Insert several cookies in order. Honors `capacity` — when overflow
    /// occurs only the most-recent `capacity` survive.
    pub fn put_many<I, T>(&mut self, host: &str, cookies: I)
    where
        I: IntoIterator<Item = T>,
        T: Into<Zeroizing<Vec<u8>>>,
    {
        for c in cookies {
            self.put(host, c);
        }
    }

    /// Pop and return the oldest unused cookie for `host`, if any.
    ///
    /// The cookie stays inside its [`Zeroizing`] wrapper across the
    /// hand-off so the bytes are wiped from RAM when the consumer
    /// drops the wrapper (typically at the end of the NTPv4 exchange
    /// that spent it). The end-to-end wrap — records parser → KE
    /// outcome → jar → caller — closes every freed-allocation surface
    /// where a spent cookie could otherwise linger between the wire
    /// and the [`Drop`] of the consumer's local.
    pub fn take(&mut self, host: &str) -> Option<Zeroizing<Vec<u8>>> {
        self.inner.get_mut(host).and_then(VecDeque::pop_front)
    }

    /// Number of cookies currently stored for `host`.
    pub fn count(&self, host: &str) -> usize {
        self.inner.get(host).map_or(0, VecDeque::len)
    }

    /// Total cookie count across every host.
    pub fn total(&self) -> usize {
        self.inner.values().map(VecDeque::len).sum()
    }

    /// Drop every cookie for `host`. Useful when a query returns an
    /// authentication failure and the entire pool must be invalidated.
    ///
    /// The drained `Zeroizing<Vec<u8>>` values wipe their bytes on
    /// drop, so an authentication-failure-driven pool invalidation
    /// does not leave the rejected cookies recoverable in freed
    /// allocations.
    pub fn clear_host(&mut self, host: &str) {
        if let Some(queue) = self.inner.get_mut(host) {
            queue.clear();
        }
    }

    pub fn hosts(&self) -> impl Iterator<Item = &str> {
        self.inner.keys().map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST_A: &str = "time.cloudflare.com";
    const HOST_B: &str = "nts.netnod.se";

    #[test]
    fn defaults_to_capacity_eight() {
        let jar = CookieJar::new();
        assert_eq!(jar.capacity(), DEFAULT_CAPACITY);
        assert_eq!(jar.total(), 0);
    }

    #[test]
    fn put_and_take_is_fifo() {
        let mut jar = CookieJar::with_capacity(4);
        for i in 0..3u8 {
            jar.put(HOST_A, vec![i]);
        }
        assert_eq!(jar.count(HOST_A), 3);
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![0])));
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![1])));
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![2])));
        assert_eq!(jar.take(HOST_A), None);
    }

    #[test]
    fn capacity_evicts_oldest() {
        let mut jar = CookieJar::with_capacity(3);
        for i in 0..5u8 {
            jar.put(HOST_A, vec![i]);
        }
        assert_eq!(jar.count(HOST_A), 3);
        // Cookies 0 and 1 evicted; 2, 3, 4 survive.
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![2])));
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![3])));
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![4])));
    }

    #[test]
    fn put_many_respects_capacity() {
        let mut jar = CookieJar::with_capacity(2);
        jar.put_many(HOST_A, [vec![0u8], vec![1], vec![2], vec![3]]);
        assert_eq!(jar.count(HOST_A), 2);
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![2])));
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![3])));
    }

    #[test]
    fn hosts_are_independent() {
        let mut jar = CookieJar::with_capacity(2);
        jar.put(HOST_A, vec![1]);
        jar.put(HOST_B, vec![2]);
        jar.put(HOST_B, vec![3]);
        assert_eq!(jar.count(HOST_A), 1);
        assert_eq!(jar.count(HOST_B), 2);
        assert_eq!(jar.total(), 3);
        let mut listed: Vec<&str> = jar.hosts().collect();
        listed.sort();
        assert_eq!(listed, vec![HOST_B, HOST_A]);
    }

    #[test]
    fn clear_host_drops_all_cookies_for_one_server() {
        let mut jar = CookieJar::new();
        jar.put_many(HOST_A, [vec![1u8], vec![2], vec![3]]);
        jar.put(HOST_B, vec![9]);
        jar.clear_host(HOST_A);
        assert_eq!(jar.count(HOST_A), 0);
        assert_eq!(jar.count(HOST_B), 1);
    }

    #[test]
    fn take_on_empty_host_returns_none() {
        let mut jar = CookieJar::new();
        assert_eq!(jar.take("never.used.example"), None);
    }

    #[test]
    #[should_panic(expected = "capacity must be > 0")]
    fn zero_capacity_panics() {
        let _ = CookieJar::with_capacity(0);
    }

    /// Pins the redacted `Debug` impl: cookies are NTS authentication
    /// material (RFC 8915 §6) and must not leak via any `{:?}`
    /// formatting site. The hand-rolled `Debug` renders per-host
    /// counts only.
    ///
    /// The negative assertion checks that the rendered output does
    /// not contain the exact substring `Vec<u8>::Debug` would
    /// produce for the sentinel cookie (e.g. `[222, 173, 190,
    /// 239, ...]`). That is the load-bearing shape: a regression
    /// that reverted to `#[derive(Debug)]` would emit cookies
    /// through the natural `Vec<Vec<u8>>` rendering, which is
    /// exactly `Vec<u8>::Debug` for each inner vector. Asserting
    /// the *concatenated* decimal sequence (rather than scanning
    /// for each individual byte in isolation) keeps the check
    /// robust against unrelated changes to `HOST_A` / `HOST_B` /
    /// `capacity` that happen to contain one of the sentinel
    /// byte values as a substring — the multi-byte sequence is
    /// vanishingly unlikely to collide with any structural field
    /// rendering.
    #[test]
    fn debug_impl_renders_counts_only_and_does_not_leak_cookie_bytes() {
        let mut jar = CookieJar::with_capacity(4);
        let sentinel = vec![0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF];
        jar.put(HOST_A, sentinel.clone());
        jar.put(HOST_A, sentinel.clone());
        jar.put(HOST_B, sentinel.clone());

        let rendered = format!("{jar:?}");

        // The redaction goal: a `Vec<u8>::Debug` rendering of the
        // sentinel (the exact shape `#[derive(Debug)]` over
        // `Vec<Vec<u8>>` would emit) must not appear in the
        // rendered output.
        let leaked_form = format!("{sentinel:?}");
        assert!(
            !rendered.contains(&leaked_form),
            "Debug output must not contain a Vec<u8>::Debug rendering of the \
             sentinel cookie ({leaked_form:?}); full output: {rendered}",
        );

        // The render must still carry the structural information
        // callers actually want from a debug print: capacity and
        // per-host counts.
        assert!(
            rendered.contains("CookieJar"),
            "Debug output must identify the type (full output: {rendered})",
        );
        assert!(
            rendered.contains("capacity: 4"),
            "Debug output must carry the capacity (full output: {rendered})",
        );
        assert!(
            rendered.contains(HOST_A) && rendered.contains(HOST_B),
            "Debug output must list each host (full output: {rendered})",
        );
        // Counts: 2 for HOST_A, 1 for HOST_B.
        assert!(
            rendered.contains(": 2") && rendered.contains(": 1"),
            "Debug output must surface per-host counts (full output: {rendered})",
        );
    }

    /// Compile-time pin that [`CookieJar::take`] returns
    /// `Option<Zeroizing<Vec<u8>>>` so the spent cookie bytes are
    /// wiped from RAM once the in-flight NTPv4 exchange drops the
    /// wrapper. A regression that reverted the return type to
    /// `Option<Vec<u8>>` would re-open the residual-memory-scrape
    /// surface this wrapper closes; the `assert_zeroizing_vec`
    /// helper accepts only `&Zeroizing<Vec<u8>>` so the test fails
    /// at compile time on that regression. Mirrors the analogous
    /// pin on [`crate::nts::ke::KeOutcome::c2s_key`] /
    /// [`crate::nts::ke::KeOutcome::s2c_key`] in `ke/tests.rs`.
    #[test]
    fn take_returns_zeroizing_wrapped_cookie() {
        fn assert_zeroizing_vec(_: &Zeroizing<Vec<u8>>) {}
        let mut jar = CookieJar::new();
        jar.put(HOST_A, vec![0xAB; 64]);
        let cookie = jar.take(HOST_A).expect("just-put cookie must pop");
        assert_zeroizing_vec(&cookie);
        // Sanity-check the inner bytes survive the wrapper (the
        // wipe happens only on drop, not on construction).
        assert_eq!(cookie.len(), 64);
        assert!(cookie.iter().all(|&b| b == 0xAB));
    }

    /// Pins the records-parser → jar handoff (bd nts-8ey): `put` and
    /// `put_many` must accept `Zeroizing<Vec<u8>>` directly so the
    /// KE-path collection (`KeOutcome::cookies: Vec<Zeroizing<Vec<u8>>>`)
    /// can be moved into the jar without unwrapping. A regression
    /// that tightened the bound back to `T: Into<Vec<u8>>` would
    /// force a manual unwrap at the call site — re-opening the
    /// intermediate-Vec liveness exposure this ticket closed.
    /// Compiles iff the bound stays `T: Into<Zeroizing<Vec<u8>>>`.
    #[test]
    fn put_accepts_zeroizing_wrapped_cookies() {
        let mut jar = CookieJar::with_capacity(4);
        // Single-cookie path: pre-wrapped Zeroizing payload.
        jar.put(HOST_A, Zeroizing::new(vec![1u8, 2, 3]));
        // Bulk path: an iterator of `Zeroizing<Vec<u8>>` — the exact
        // shape `outcome.cookies.into_iter()` produces in `nts.rs`.
        jar.put_many(
            HOST_A,
            [
                Zeroizing::new(vec![4u8, 5, 6]),
                Zeroizing::new(vec![7u8, 8, 9]),
            ],
        );
        assert_eq!(jar.count(HOST_A), 3);
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![1, 2, 3])));
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![4, 5, 6])));
        assert_eq!(jar.take(HOST_A), Some(Zeroizing::new(vec![7, 8, 9])));
    }
}
