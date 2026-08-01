//! Single-server NTS cookie store (RFC 8915 §6).
//!
//! Holds one bounded FIFO queue. Each `nts_query` spends one cookie via
//! [`CookieJar::take`] and ingests fresh cookies from the response via
//! [`CookieJar::put_many`]. RFC 8915 §6 mandates that cookies be used at
//! most once and that clients keep "no more than 8 unused cookies" per server
//! to bound exposure if the host's KE state is later compromised.
//!
//! The jar holds cookies for exactly one server because its sole owner —
//! `crate::api::nts::Session` — is itself 1:1 with a negotiated
//! `host:port`. See [`CookieJar`] for why that is expressed structurally
//! rather than by keying on a host.

use std::collections::VecDeque;
use std::fmt;
use std::num::NonZeroUsize;

use zeroize::Zeroizing;

/// Default jar capacity. RFC 8915 §6 advises clients keep at most 8
/// unused cookies per server to bound exposure if KE state is later
/// compromised; this matches the cap several public deployments (e.g.
/// Cloudflare) deliver in the initial KE response. The count returned by any
/// given server is per RFC 8915 §4 a matter of server policy.
pub const DEFAULT_CAPACITY: NonZeroUsize = NonZeroUsize::new(8).unwrap();

/// Hard cap on a single cookie's length, in octets.
///
/// RFC 8915 specifies no maximum: §4.1.6 makes the NTS-KE NewCookie body
/// an opaque blob, and §5.4 makes the NTP NTS Cookie extension the same.
/// Real deployments are an order of magnitude below this cap —
/// Cloudflare, Netnod and NTS.net.nz all issue cookies around 100 octets
/// (the `ntpd-rs` reference cookie encoding is 104 for AES-SIV-CMAC-256).
///
/// Without a client-side bound, a cookie is limited only by the enclosing
/// message: up to [`super::ke::NTS_KE_READ_BUDGET`] (16 KiB) from a KE
/// response, or the datagram size from an NTP reply. That length then
/// propagates into the *next* request, because
/// [`super::ntp::build_client_request`] sizes each NTS Cookie Placeholder
/// to `req.cookie.len()` for the RFC 8915 §5.7 amplification defence — so
/// one multi-KiB cookie inflates every subsequent client datagram by
/// roughly twice its size, risking path-MTU black holes, fragmentation,
/// and send failures surfacing as opaque network errors.
///
/// 512 leaves ~5× headroom over observed cookie sizes while keeping the
/// worst-case request comfortably inside
/// [`super::ntp::MAX_CLIENT_PACKET_BYTES`].
pub const MAX_COOKIE_LEN: usize = 512;

/// FIFO cookie store for a single NTS server.
///
/// Eviction is FIFO: when the queue is at capacity, the oldest cookie is
/// dropped to make room for the newest. `take` also pops from the front so
/// the oldest cookie in the pool is spent first; combined this means a cookie
/// is either spent or evicted (never reused), satisfying RFC 8915 §6.
///
/// The jar holds one queue rather than a host-keyed map because its only
/// owner, `crate::api::nts::Session`, is 1:1 with a negotiated
/// `host:port` and knows that host itself. A host-keyed jar made the
/// binding a runtime agreement between caller and store: a caller that
/// deposited under the KE host and drew under the NTPv4 host — which
/// diverge whenever the KE response carries a Server record (RFC 8915
/// §4.1.7) — would strand the deposited cookies behind a second key and
/// see a phantom empty jar, with no type error and no panic. Dropping
/// the key makes that mismatch unrepresentable (bd nts-r11f.9).
///
/// Cookies are NTS authentication material (RFC 8915 §6): a recovered
/// cookie lets an attacker impersonate the original client to the NTS
/// server for the lifetime of the cookie's server-side AEAD key. The
/// jar therefore treats cookie bytes the way [`crate::nts::aead`]
/// treats AEAD key material: each stored cookie is held in
/// [`Zeroizing<Vec<u8>>`], so the natural drop chain
/// ([`Self::put`] overflow eviction, [`Self::clear`] drain,
/// [`CookieJar`] going out of scope) wipes the bytes from RAM before
/// the backing allocation is returned to the allocator. The
/// [`fmt::Debug`] implementation renders only the cookie count so
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
///
/// CONCURRENCY: this type auto-derives `Send + Sync` (its fields —
/// `NonZeroUsize`, `VecDeque`, `Zeroizing<Vec<u8>>` — are all
/// `Send + Sync`), so the marker traits alone do *not* warn callers
/// off concurrent use. The real constraint is that it carries **no
/// interior mutability**: every mutator ([`Self::put`],
/// [`Self::put_many`], [`Self::take`], [`Self::clear`]) takes
/// `&mut self`, so two threads cannot mutate the same jar without
/// external synchronisation. A future caller that reaches for
/// `CookieJar` directly outside [`crate::api::nts`] must wrap it in a
/// `Mutex` (or equivalent) before sharing it across threads;
/// [`crate::api::nts`]'s `SessionTable` already does this by owning
/// every jar inside its `Mutex<HashMap<String, Session>>` and only
/// touching it under that lock.
///
/// Deliberately **not** `Clone`. A clone would deep-copy every cookie
/// into a second set of heap allocations with an independent drop
/// point, so the wipe-on-drop guarantee above would hold for each copy
/// separately rather than for the material as a whole — widening the
/// window in which the bytes are resident. Nothing needs it: the jar
/// is owned by exactly one `Session` and reached only through `&mut`.
pub struct CookieJar {
    capacity: NonZeroUsize,
    inner: VecDeque<Zeroizing<Vec<u8>>>,
}

impl fmt::Debug for CookieJar {
    /// Render the count only; cookies are NTS authentication material
    /// (RFC 8915 §6) and must not leak via accidental `{:?}` in logs,
    /// panic messages, or diagnostic output. Mirrors the redacted
    /// `Debug` on [`crate::nts::ke::KeOutcome`] so the same hygiene
    /// applies at both ends of the KE → cache pipeline.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CookieJar")
            .field("capacity", &self.capacity.get())
            .field("count", &self.inner.len())
            .finish()
    }
}

impl Default for CookieJar {
    fn default() -> Self {
        Self::with_capacity(DEFAULT_CAPACITY)
    }
}

impl CookieJar {
    /// Construct an empty jar with the default cap.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Construct an empty jar holding at most `capacity` cookies.
    ///
    /// `capacity` is a [`NonZeroUsize`] rather than a plain `usize`
    /// because a zero-capacity jar would evict every cookie on
    /// insertion, leaving [`Self::take`] permanently empty and every
    /// query reporting `NoCookies`. Encoding the bound in the type
    /// rejects that at the call site instead of panicking here
    /// (bd nts-r11f.11 / NTS-132).
    #[must_use]
    pub fn with_capacity(capacity: NonZeroUsize) -> Self {
        Self {
            capacity,
            inner: VecDeque::new(),
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity.get()
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
    /// pop here, [`Self::clear`] drain, [`CookieJar`] going out
    /// of scope — without any further manual `zeroize()` calls.
    pub fn put<T>(&mut self, cookie: T)
    where
        T: Into<Zeroizing<Vec<u8>>>,
    {
        self.inner.push_back(cookie.into());
        while self.inner.len() > self.capacity.get() {
            // The popped `Zeroizing<Vec<u8>>` wipes its bytes when
            // it drops at the end of this iteration; no explicit
            // `zeroize()` call is needed.
            let _ = self.inner.pop_front();
        }
    }

    /// Insert several cookies in order. Honors `capacity` — when overflow
    /// occurs only the most-recent `capacity` survive.
    pub fn put_many<I, T>(&mut self, cookies: I)
    where
        I: IntoIterator<Item = T>,
        T: Into<Zeroizing<Vec<u8>>>,
    {
        for c in cookies {
            self.put(c);
        }
    }

    /// Pop and return the oldest unused cookie, if any.
    ///
    /// The cookie stays inside its [`Zeroizing`] wrapper across the
    /// hand-off so the bytes are wiped from RAM when the consumer
    /// drops the wrapper (typically at the end of the NTPv4 exchange
    /// that spent it). The end-to-end wrap — records parser → KE
    /// outcome → jar → caller — closes every freed-allocation surface
    /// where a spent cookie could otherwise linger between the wire
    /// and the [`Drop`] of the consumer's local.
    pub fn take(&mut self) -> Option<Zeroizing<Vec<u8>>> {
        self.inner.pop_front()
    }

    /// Number of cookies currently stored.
    pub fn count(&self) -> usize {
        self.inner.len()
    }

    /// Drop every cookie. Useful when a query returns an
    /// authentication failure and the entire pool must be invalidated.
    ///
    /// The drained `Zeroizing<Vec<u8>>` values wipe their bytes on
    /// drop, so an authentication-failure-driven pool invalidation
    /// does not leave the rejected cookies recoverable in freed
    /// allocations.
    pub fn clear(&mut self) {
        self.inner.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shorthand for the [`NonZeroUsize`] capacities the tests below
    /// build. Panics on zero, which is exactly what the production
    /// signature now makes unreachable — the panic lives in the test
    /// helper rather than in [`CookieJar::with_capacity`].
    fn cap(n: usize) -> NonZeroUsize {
        NonZeroUsize::new(n).expect("test capacity must be non-zero")
    }

    /// Pins the headroom relationship between the two caps added for bd
    /// nts-r11f.4. [`crate::nts::ntp::build_client_request`] emits the
    /// cookie once plus once per placeholder, so the worst-case
    /// production request (one placeholder) carries two cookie-sized
    /// extensions. Raising [`MAX_COOKIE_LEN`] past roughly half of
    /// [`crate::nts::ntp::MAX_CLIENT_PACKET_BYTES`] would make the packet
    /// guard fire on every ordinary request; fail here rather than in
    /// production if that relationship is ever broken.
    #[test]
    fn cookie_cap_leaves_headroom_under_packet_cap() {
        let packet_cap = crate::nts::ntp::MAX_CLIENT_PACKET_BYTES;
        assert!(
            MAX_COOKIE_LEN * 2 < packet_cap,
            "two cookie-sized extensions ({}) must fit inside the {packet_cap}-byte packet cap",
            MAX_COOKIE_LEN * 2,
        );
    }

    #[test]
    fn defaults_to_capacity_eight() {
        let jar = CookieJar::new();
        assert_eq!(jar.capacity(), DEFAULT_CAPACITY.get());
        assert_eq!(jar.count(), 0);
    }

    #[test]
    fn put_and_take_is_fifo() {
        let mut jar = CookieJar::with_capacity(cap(4));
        for i in 0..3u8 {
            jar.put(vec![i]);
        }
        assert_eq!(jar.count(), 3);
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![0])));
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![1])));
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![2])));
        assert_eq!(jar.take(), None);
    }

    #[test]
    fn capacity_evicts_oldest() {
        let mut jar = CookieJar::with_capacity(cap(3));
        for i in 0..5u8 {
            jar.put(vec![i]);
        }
        assert_eq!(jar.count(), 3);
        // Cookies 0 and 1 evicted; 2, 3, 4 survive.
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![2])));
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![3])));
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![4])));
    }

    #[test]
    fn put_many_respects_capacity() {
        let mut jar = CookieJar::with_capacity(cap(2));
        jar.put_many([vec![0u8], vec![1], vec![2], vec![3]]);
        assert_eq!(jar.count(), 2);
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![2])));
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![3])));
    }

    #[test]
    fn clear_drops_every_cookie() {
        let mut jar = CookieJar::new();
        jar.put_many([vec![1u8], vec![2], vec![3]]);
        jar.clear();
        assert_eq!(jar.count(), 0);
        assert_eq!(jar.take(), None);
    }

    #[test]
    fn take_on_empty_jar_returns_none() {
        let mut jar = CookieJar::new();
        assert_eq!(jar.take(), None);
    }

    /// Pins the non-panicking capacity contract (bd nts-r11f.11 /
    /// NTS-132). [`CookieJar::with_capacity`] takes a
    /// [`NonZeroUsize`], so a zero capacity cannot be expressed: the
    /// rejection happens where the value is built, as a `None` from
    /// [`NonZeroUsize::new`], rather than as a panic inside the
    /// constructor. `with_capacity(0)` no longer compiles, which is
    /// the property this test stands in for — a regression to a plain
    /// `usize` parameter would make the assertion below meaningless
    /// but would also re-admit the panicking call site.
    #[test]
    fn zero_capacity_is_unrepresentable() {
        assert!(
            NonZeroUsize::new(0).is_none(),
            "a zero capacity must not survive NonZeroUsize construction",
        );
        assert_eq!(DEFAULT_CAPACITY.get(), 8);
    }

    /// Pins the redacted `Debug` impl: cookies are NTS authentication
    /// material (RFC 8915 §6) and must not leak via any `{:?}`
    /// formatting site. The hand-rolled `Debug` renders the capacity
    /// and the cookie count only.
    ///
    /// The negative assertion checks that the rendered output does
    /// not contain the exact substring `Vec<u8>::Debug` would
    /// produce for the sentinel cookie (e.g. `[222, 173, 190,
    /// 239, ...]`). That is the load-bearing shape: a regression
    /// that reverted to `#[derive(Debug)]` would emit cookies
    /// through the natural `VecDeque<Vec<u8>>` rendering, which is
    /// exactly `Vec<u8>::Debug` for each inner vector. Asserting
    /// the *concatenated* decimal sequence (rather than scanning
    /// for each individual byte in isolation) keeps the check
    /// robust against unrelated changes to `capacity` that happen
    /// to contain one of the sentinel byte values as a substring —
    /// the multi-byte sequence is vanishingly unlikely to collide
    /// with any structural field rendering.
    #[test]
    fn debug_impl_renders_counts_only_and_does_not_leak_cookie_bytes() {
        let mut jar = CookieJar::with_capacity(cap(4));
        let sentinel = vec![0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF];
        jar.put(sentinel.clone());
        jar.put(sentinel.clone());
        jar.put(sentinel.clone());

        let rendered = format!("{jar:?}");

        // The redaction goal: a `Vec<u8>::Debug` rendering of the
        // sentinel (the exact shape `#[derive(Debug)]` over
        // `VecDeque<Vec<u8>>` would emit) must not appear in the
        // rendered output.
        let leaked_form = format!("{sentinel:?}");
        assert!(
            !rendered.contains(&leaked_form),
            "Debug output must not contain a Vec<u8>::Debug rendering of the \
             sentinel cookie ({leaked_form:?}); full output: {rendered}",
        );

        // The render must still carry the structural information
        // callers actually want from a debug print: capacity and
        // cookie count.
        assert!(
            rendered.contains("CookieJar"),
            "Debug output must identify the type (full output: {rendered})",
        );
        assert!(
            rendered.contains("capacity: 4"),
            "Debug output must carry the capacity (full output: {rendered})",
        );
        assert!(
            rendered.contains("count: 3"),
            "Debug output must surface the cookie count (full output: {rendered})",
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
        jar.put(vec![0xAB; 64]);
        let cookie = jar.take().expect("just-put cookie must pop");
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
        let mut jar = CookieJar::with_capacity(cap(4));
        // Single-cookie path: pre-wrapped Zeroizing payload.
        jar.put(Zeroizing::new(vec![1u8, 2, 3]));
        // Bulk path: an iterator of `Zeroizing<Vec<u8>>` — the exact
        // shape `outcome.cookies.into_iter()` produces in `nts.rs`.
        jar.put_many([
            Zeroizing::new(vec![4u8, 5, 6]),
            Zeroizing::new(vec![7u8, 8, 9]),
        ]);
        assert_eq!(jar.count(), 3);
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![1, 2, 3])));
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![4, 5, 6])));
        assert_eq!(jar.take(), Some(Zeroizing::new(vec![7, 8, 9])));
    }
}
