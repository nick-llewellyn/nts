//! Per-host NTS cookie store (RFC 8915 §6).
//!
//! Holds a bounded FIFO queue per NTS-KE host. Each `nts_query` spends one
//! cookie via [`CookieJar::take`] and ingests fresh cookies from the response
//! via [`CookieJar::put_many`]. RFC 8915 §6 mandates that cookies be used at
//! most once and that clients keep "no more than 8 unused cookies" per server
//! to bound exposure if the host's KE state is later compromised.

use std::collections::{HashMap, VecDeque};

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
#[derive(Debug, Clone)]
pub struct CookieJar {
    capacity: usize,
    inner: HashMap<String, VecDeque<Vec<u8>>>,
}

impl Default for CookieJar {
    fn default() -> Self {
        Self::with_capacity(DEFAULT_CAPACITY)
    }
}

impl CookieJar {
    /// Construct an empty jar with the default per-host cap.
    pub fn new() -> Self {
        Self::default()
    }

    /// Construct an empty jar with `capacity` cookies per host. Panics if zero.
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
    pub fn put(&mut self, host: &str, cookie: Vec<u8>) {
        let queue = self.inner.entry(host.to_owned()).or_default();
        queue.push_back(cookie);
        while queue.len() > self.capacity {
            queue.pop_front();
        }
    }

    /// Insert several cookies in order. Honors `capacity` — when overflow
    /// occurs only the most-recent `capacity` survive.
    pub fn put_many<I, T>(&mut self, host: &str, cookies: I)
    where
        I: IntoIterator<Item = T>,
        T: Into<Vec<u8>>,
    {
        for c in cookies {
            self.put(host, c.into());
        }
    }

    /// Pop and return the oldest unused cookie for `host`, if any.
    pub fn take(&mut self, host: &str) -> Option<Vec<u8>> {
        self.inner.get_mut(host).and_then(|q| q.pop_front())
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
        assert_eq!(jar.take(HOST_A), Some(vec![0]));
        assert_eq!(jar.take(HOST_A), Some(vec![1]));
        assert_eq!(jar.take(HOST_A), Some(vec![2]));
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
        assert_eq!(jar.take(HOST_A), Some(vec![2]));
        assert_eq!(jar.take(HOST_A), Some(vec![3]));
        assert_eq!(jar.take(HOST_A), Some(vec![4]));
    }

    #[test]
    fn put_many_respects_capacity() {
        let mut jar = CookieJar::with_capacity(2);
        jar.put_many(HOST_A, [vec![0u8], vec![1], vec![2], vec![3]]);
        assert_eq!(jar.count(HOST_A), 2);
        assert_eq!(jar.take(HOST_A), Some(vec![2]));
        assert_eq!(jar.take(HOST_A), Some(vec![3]));
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
}
