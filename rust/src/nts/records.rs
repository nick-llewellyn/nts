//! NTS-KE record codec (RFC 8915 §4).
//!
//! Operates on byte slices and `Vec<u8>` only. The handshake driver in
//! `super::ke` is responsible for moving these over a TLS stream.

use std::fmt;

/// Hard cap on a single NTS-KE message we'll accept on the wire.
///
/// RFC 8915 does not specify a numeric limit; 64 KiB is generous for the
/// typical 8-cookie response (~1 KiB) while bounding memory use.
pub const MAX_MESSAGE_BYTES: usize = 65_536;

/// Record-type identifiers from the IANA registry (RFC 8915 §7.5).
pub mod record_type {
    pub const END_OF_MESSAGE: u16 = 0;
    pub const NEXT_PROTOCOL: u16 = 1;
    pub const ERROR: u16 = 2;
    pub const WARNING: u16 = 3;
    pub const AEAD_ALGORITHM: u16 = 4;
    pub const NEW_COOKIE: u16 = 5;
    pub const NTPV4_SERVER: u16 = 6;
    pub const NTPV4_PORT: u16 = 7;
}

/// IANA "Network Time Security Next Protocols" registry (RFC 8915 §7.6).
pub const NEXT_PROTO_NTPV4: u16 = 0;

/// IANA "AEAD Algorithm" registry — the IDs we either support or recognize.
///
/// Per the registry at <https://www.iana.org/assignments/aead-parameters>,
/// SIV-CMAC variants and GCM-SIV variants share the registry; RFC 8915 §5.1
/// only lists the SIV-CMAC family but RFC 8452 (GCM-SIV) is registered too
/// and sees field deployment.
pub mod aead {
    pub const AES_SIV_CMAC_256: u16 = 15;
    pub const AES_SIV_CMAC_384: u16 = 16;
    pub const AES_SIV_CMAC_512: u16 = 17;
    pub const AES_128_GCM_SIV: u16 = 30;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub critical: bool,
    pub kind: RecordKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RecordKind {
    EndOfMessage,
    NextProtocol(Vec<u16>),
    Error(ErrorCode),
    Warning(WarningCode),
    AeadAlgorithm(Vec<u16>),
    NewCookie(Vec<u8>),
    Server(String),
    Port(u16),
    Unknown { record_type: u16, body: Vec<u8> },
}

/// Typed wrapper over the u16 payload of an NTS-KE Error record
/// (RFC 8915 §4.1.3 record type 2). The three IANA-registered codes
/// in the original specification get named variants; any other value
/// — including future IANA registry additions — round-trips through
/// the `Unknown(u16)` catch-all so a non-conforming server cannot
/// crash the parser by sending an unrecognized code, and the
/// numeric payload remains visible to logs and to the `From<_> for
/// u16` round-trip.
///
/// Mirrors the shape used by `pendulum-project/ntpd-rs`'s
/// `nts::ErrorCode` (v1.7.2) so the two implementations agree on
/// the canonical naming of the three spec'd codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    /// RFC 8915 §4.1.3 code 0 — server received a critical record
    /// type it does not understand.
    UnrecognizedCriticalRecord,
    /// RFC 8915 §4.1.3 code 1 — request was malformed or otherwise
    /// unacceptable to the server.
    BadRequest,
    /// RFC 8915 §4.1.3 code 2 — server failed to process an
    /// otherwise-acceptable request for an internal reason.
    InternalServerError,
    /// Any code outside the IANA-registered set above. Preserved as
    /// the raw u16 so the diagnostic and any round-trip back onto
    /// the wire keep the server's choice intact.
    Unknown(u16),
}

impl From<u16> for ErrorCode {
    fn from(value: u16) -> Self {
        match value {
            0 => Self::UnrecognizedCriticalRecord,
            1 => Self::BadRequest,
            2 => Self::InternalServerError,
            other => Self::Unknown(other),
        }
    }
}

impl From<ErrorCode> for u16 {
    fn from(code: ErrorCode) -> Self {
        match code {
            ErrorCode::UnrecognizedCriticalRecord => 0,
            ErrorCode::BadRequest => 1,
            ErrorCode::InternalServerError => 2,
            ErrorCode::Unknown(other) => other,
        }
    }
}

impl ErrorCode {
    /// Numeric code that will be written to the wire for this
    /// variant. Convenience alias for `u16::from(self)`; useful at
    /// FFI boundaries where the named variant is not the natural
    /// payload.
    #[must_use]
    pub fn as_u16(self) -> u16 {
        self.into()
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnrecognizedCriticalRecord => f.write_str("UnrecognizedCriticalRecord"),
            Self::BadRequest => f.write_str("BadRequest"),
            Self::InternalServerError => f.write_str("InternalServerError"),
            Self::Unknown(code) => write!(f, "Unknown({code})"),
        }
    }
}

/// Typed wrapper over the u16 payload of an NTS-KE Warning record
/// (RFC 8915 §4.1.4 record type 3). The IANA registry for warning
/// codes is empty as of RFC 8915, so every observed value lands in
/// the `Unknown(u16)` catch-all today; the typed wrapper exists so
/// future registry additions can be promoted to named variants
/// without changing every call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WarningCode {
    /// Any code observed on the wire. The IANA registry is empty
    /// at the spec's publication time; future named variants will
    /// take precedence over this catch-all when added.
    Unknown(u16),
}

impl From<u16> for WarningCode {
    fn from(value: u16) -> Self {
        Self::Unknown(value)
    }
}

impl From<WarningCode> for u16 {
    fn from(code: WarningCode) -> Self {
        match code {
            WarningCode::Unknown(other) => other,
        }
    }
}

impl WarningCode {
    /// Numeric code that will be written to the wire for this
    /// variant. Convenience alias for `u16::from(self)`; useful at
    /// FFI boundaries where the named variant is not the natural
    /// payload.
    #[must_use]
    pub fn as_u16(self) -> u16 {
        self.into()
    }
}

impl fmt::Display for WarningCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unknown(code) => write!(f, "Unknown({code})"),
        }
    }
}

#[derive(Debug)]
pub enum CodecError {
    MessageTooLarge { actual: usize },
    TruncatedHeader,
    BodyOverflow { claimed: usize, remaining: usize },
    OddU16Array { len: usize },
    BodyLengthMismatch { actual: usize, expected: usize },
    InvalidUtf8,
    MissingTerminator,
    NonEmptyEndOfMessage,
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MessageTooLarge { actual } => write!(
                f,
                "NTS-KE message too large: {actual} bytes (cap {MAX_MESSAGE_BYTES})",
            ),
            Self::TruncatedHeader => f.write_str("truncated NTS-KE record header"),
            Self::BodyOverflow { claimed, remaining } => write!(
                f,
                "record body length {claimed} exceeds remaining {remaining} bytes",
            ),
            Self::OddU16Array { len } => {
                write!(f, "u16-array record body length {len} is not even")
            }
            Self::BodyLengthMismatch { actual, expected } => {
                write!(f, "body length {actual} != expected {expected}")
            }
            Self::InvalidUtf8 => f.write_str("NTPv4-Server record contained invalid UTF-8"),
            Self::MissingTerminator => f.write_str("NTS-KE message has no End-of-Message record"),
            Self::NonEmptyEndOfMessage => f.write_str("End-of-Message record body must be empty"),
        }
    }
}

impl std::error::Error for CodecError {}

impl Record {
    pub const fn new(critical: bool, kind: RecordKind) -> Self {
        Self { critical, kind }
    }

    /// Number of body octets this record will serialize to.
    pub fn body_len(&self) -> usize {
        match &self.kind {
            RecordKind::EndOfMessage => 0,
            RecordKind::NextProtocol(v) | RecordKind::AeadAlgorithm(v) => v.len() * 2,
            RecordKind::Error(_) | RecordKind::Warning(_) | RecordKind::Port(_) => 2,
            RecordKind::NewCookie(b) => b.len(),
            RecordKind::Server(s) => s.len(),
            RecordKind::Unknown { body, .. } => body.len(),
        }
    }

    fn record_type(&self) -> u16 {
        match &self.kind {
            RecordKind::EndOfMessage => record_type::END_OF_MESSAGE,
            RecordKind::NextProtocol(_) => record_type::NEXT_PROTOCOL,
            RecordKind::Error(_) => record_type::ERROR,
            RecordKind::Warning(_) => record_type::WARNING,
            RecordKind::AeadAlgorithm(_) => record_type::AEAD_ALGORITHM,
            RecordKind::NewCookie(_) => record_type::NEW_COOKIE,
            RecordKind::Server(_) => record_type::NTPV4_SERVER,
            RecordKind::Port(_) => record_type::NTPV4_PORT,
            RecordKind::Unknown { record_type, .. } => *record_type,
        }
    }

    fn write_to(&self, out: &mut Vec<u8>) {
        let mut header = self.record_type();
        if self.critical {
            header |= 0x8000;
        }
        out.extend_from_slice(&header.to_be_bytes());
        let body_len = self.body_len() as u16;
        out.extend_from_slice(&body_len.to_be_bytes());
        match &self.kind {
            RecordKind::EndOfMessage => {}
            RecordKind::NextProtocol(v) | RecordKind::AeadAlgorithm(v) => {
                for n in v {
                    out.extend_from_slice(&n.to_be_bytes());
                }
            }
            // The three single-u16-body record types share the same
            // wire shape but no longer share a Rust type after the
            // typed `ErrorCode` / `WarningCode` wrappers landed
            // (bd nts-zqn). Each arm calls `as_u16()` (for the typed
            // wrappers) or uses the value directly (for `Port`'s
            // remaining bare `u16`); the `to_be_bytes` invocation
            // is identical across the three.
            RecordKind::Error(code) => out.extend_from_slice(&code.as_u16().to_be_bytes()),
            RecordKind::Warning(code) => out.extend_from_slice(&code.as_u16().to_be_bytes()),
            RecordKind::Port(p) => out.extend_from_slice(&p.to_be_bytes()),
            RecordKind::NewCookie(b) | RecordKind::Unknown { body: b, .. } => {
                out.extend_from_slice(b);
            }
            RecordKind::Server(s) => out.extend_from_slice(s.as_bytes()),
        }
    }
}

/// Serialize a sequence of records, in order, into a single message.
///
/// Caller is responsible for placing `RecordKind::EndOfMessage` last
/// (RFC 8915 §4 — every NTS-KE message ends with an EndOfMessage
/// record). Both an empty record slice and a non-empty slice whose
/// last record is not `EndOfMessage` panic via `assert!`, which fires
/// in both debug and release builds. The function runs at most once
/// per KE handshake and the check is a single tail comparison plus a
/// pattern match, so the runtime cost is irrelevant; the assertion
/// is here to fail at the offending call site rather than emit a
/// malformed wire packet that the peer would reject as an opaque
/// parse error.
///
/// Earlier this check used `debug_assert!`, which compiles to nothing
/// in release builds — so a release-mode regression in any call site
/// (or in a future caller that builds the record list dynamically)
/// would silently emit a malformed message. Promoted to `assert!` so
/// the invariant is load-bearing in shipped binaries too.
pub fn serialize_message(records: &[Record]) -> Vec<u8> {
    assert!(
        records
            .last()
            .is_some_and(|r| matches!(r.kind, RecordKind::EndOfMessage)),
        "RFC 8915 §4: NTS-KE message must end with EndOfMessage record",
    );
    let total: usize = records.iter().map(|r| 4 + r.body_len()).sum();
    let mut out = Vec::with_capacity(total);
    for r in records {
        r.write_to(&mut out);
    }
    out
}

/// Parse a complete NTS-KE message into a record list.
///
/// On success the last record is guaranteed to be `EndOfMessage` and any
/// `EndOfMessage` body is required to be empty (RFC 8915 §4.1.1).
pub fn parse_message(bytes: &[u8]) -> Result<Vec<Record>, CodecError> {
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(CodecError::MessageTooLarge {
            actual: bytes.len(),
        });
    }
    let mut out = Vec::new();
    let mut cursor = 0usize;
    let mut saw_terminator = false;
    while cursor < bytes.len() {
        if saw_terminator {
            return Err(CodecError::BodyLengthMismatch {
                actual: bytes.len() - cursor,
                expected: 0,
            });
        }
        if bytes.len() - cursor < 4 {
            return Err(CodecError::TruncatedHeader);
        }
        let header = u16::from_be_bytes([bytes[cursor], bytes[cursor + 1]]);
        let body_len = u16::from_be_bytes([bytes[cursor + 2], bytes[cursor + 3]]) as usize;
        cursor += 4;
        let critical = (header & 0x8000) != 0;
        let record_type = header & 0x7FFF;
        let remaining = bytes.len() - cursor;
        if body_len > remaining {
            return Err(CodecError::BodyOverflow {
                claimed: body_len,
                remaining,
            });
        }
        let body = &bytes[cursor..cursor + body_len];
        cursor += body_len;
        let kind = decode_kind(record_type, body)?;
        if matches!(kind, RecordKind::EndOfMessage) {
            saw_terminator = true;
        }
        out.push(Record { critical, kind });
    }
    if !saw_terminator {
        return Err(CodecError::MissingTerminator);
    }
    Ok(out)
}

fn decode_kind(record_type: u16, body: &[u8]) -> Result<RecordKind, CodecError> {
    match record_type {
        record_type::END_OF_MESSAGE => {
            if !body.is_empty() {
                return Err(CodecError::NonEmptyEndOfMessage);
            }
            Ok(RecordKind::EndOfMessage)
        }
        record_type::NEXT_PROTOCOL => Ok(RecordKind::NextProtocol(decode_u16_array(body)?)),
        record_type::AEAD_ALGORITHM => Ok(RecordKind::AeadAlgorithm(decode_u16_array(body)?)),
        record_type::ERROR => Ok(RecordKind::Error(ErrorCode::from(decode_u16_scalar(body)?))),
        record_type::WARNING => Ok(RecordKind::Warning(WarningCode::from(decode_u16_scalar(
            body,
        )?))),
        record_type::NTPV4_PORT => Ok(RecordKind::Port(decode_u16_scalar(body)?)),
        record_type::NEW_COOKIE => Ok(RecordKind::NewCookie(body.to_vec())),
        record_type::NTPV4_SERVER => std::str::from_utf8(body)
            .map(|s| RecordKind::Server(s.to_owned()))
            .map_err(|_| CodecError::InvalidUtf8),
        other => Ok(RecordKind::Unknown {
            record_type: other,
            body: body.to_vec(),
        }),
    }
}

fn decode_u16_array(body: &[u8]) -> Result<Vec<u16>, CodecError> {
    if !body.len().is_multiple_of(2) {
        return Err(CodecError::OddU16Array { len: body.len() });
    }
    Ok(body
        .chunks_exact(2)
        .map(|c| u16::from_be_bytes([c[0], c[1]]))
        .collect())
}

fn decode_u16_scalar(body: &[u8]) -> Result<u16, CodecError> {
    if body.len() != 2 {
        return Err(CodecError::BodyLengthMismatch {
            actual: body.len(),
            expected: 2,
        });
    }
    Ok(u16::from_be_bytes([body[0], body[1]]))
}

// Compile-time pin that the protocol-code enums implement
// `Hash`. The `derive(Hash)` lines above are added so callers can
// key counters and `HashMap`s on protocol codes (e.g.
// per-`ErrorCode` error-frequency telemetry) without local
// boilerplate; without an active use site today, a future drop of
// the derive would otherwise go silently. The closure compiles only
// if every named type satisfies `T: Hash`; it is never called and
// has no runtime cost (bd nts-b6m sub-item A). The leading `_` on
// the const name is the standard Rust opt-out from `dead_code`, so
// no lint suppression is needed here.
const _ASSERT_HASH_DERIVES: fn() = || {
    fn requires_hash<T: std::hash::Hash>() {}
    requires_hash::<RecordKind>();
    requires_hash::<ErrorCode>();
    requires_hash::<WarningCode>();
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nts::test_helpers::rec;

    #[test]
    fn round_trip_full_message() {
        let msg = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(
                true,
                RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            ),
            rec(false, RecordKind::NewCookie(vec![0xAA; 100])),
            rec(false, RecordKind::Server("time.example.com".to_owned())),
            rec(false, RecordKind::Port(123)),
            rec(false, RecordKind::Warning(WarningCode::Unknown(0x1234))),
            rec(true, RecordKind::EndOfMessage),
        ];
        let bytes = serialize_message(&msg);
        let parsed = parse_message(&bytes).expect("round-trip");
        assert_eq!(parsed, msg);
    }

    #[test]
    fn critical_bit_preserved() {
        let critical = serialize_message(&[
            rec(true, RecordKind::Port(456)),
            rec(true, RecordKind::EndOfMessage),
        ]);
        // First byte: 0x80 | 0x00 (high bit) | 0x07 (NTPV4_PORT) = 0x80, 0x07.
        assert_eq!(critical[0], 0x80);
        assert_eq!(critical[1], 0x07);

        let non_critical = serialize_message(&[
            rec(false, RecordKind::Port(456)),
            rec(true, RecordKind::EndOfMessage),
        ]);
        assert_eq!(non_critical[0], 0x00);
        assert_eq!(non_critical[1], 0x07);
    }

    #[test]
    fn unknown_record_round_trips() {
        let msg = vec![
            rec(
                true,
                RecordKind::Unknown {
                    record_type: 0x1234,
                    body: vec![1, 2, 3, 4, 5],
                },
            ),
            rec(true, RecordKind::EndOfMessage),
        ];
        let parsed = parse_message(&serialize_message(&msg)).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn rejects_truncated_header() {
        let bytes = vec![0x80, 0x00, 0x00];
        match parse_message(&bytes) {
            Err(CodecError::TruncatedHeader) => {}
            other => panic!("expected TruncatedHeader, got {other:?}"),
        }
    }

    #[test]
    fn rejects_body_overflow() {
        // Header claims body of 8 bytes but only 2 follow.
        let bytes = vec![0x80, 0x00, 0x00, 0x08, 0xAA, 0xBB];
        match parse_message(&bytes) {
            Err(CodecError::BodyOverflow {
                claimed: 8,
                remaining: 2,
            }) => {}
            other => panic!("expected BodyOverflow, got {other:?}"),
        }
    }

    #[test]
    fn rejects_odd_u16_array_in_aead_record() {
        // AEAD record (type 4) with body length 3 (not a multiple of 2).
        let bytes = vec![0x80, 0x04, 0x00, 0x03, 0x00, 0x0F, 0x00];
        match parse_message(&bytes) {
            Err(CodecError::OddU16Array { len: 3 }) => {}
            other => panic!("expected OddU16Array, got {other:?}"),
        }
    }

    #[test]
    fn rejects_missing_terminator() {
        // Single non-EOM record (Port=123) with no End-of-Message after
        // it. The bytes are hand-assembled rather than routed through
        // `serialize_message` because the EOM-terminator guard in that
        // helper (RFC 8915 §4) would panic on the missing terminator
        // before we ever exercised the parser path under test.
        //
        // Wire layout: critical=0, type=NTPV4_PORT(7), len=2, body=0x007B.
        let bytes = vec![0x00, record_type::NTPV4_PORT as u8, 0x00, 0x02, 0x00, 0x7B];
        match parse_message(&bytes) {
            Err(CodecError::MissingTerminator) => {}
            other => panic!("expected MissingTerminator, got {other:?}"),
        }
    }

    #[test]
    fn rejects_non_empty_end_of_message() {
        // EOM (type 0, critical) with a non-empty body.
        let bytes = vec![0x80, 0x00, 0x00, 0x02, 0xAA, 0xBB];
        match parse_message(&bytes) {
            Err(CodecError::NonEmptyEndOfMessage) => {}
            other => panic!("expected NonEmptyEndOfMessage, got {other:?}"),
        }
    }

    #[test]
    fn rejects_bytes_after_terminator() {
        let mut bytes = serialize_message(&[rec(true, RecordKind::EndOfMessage)]);
        bytes.extend_from_slice(&[0x00, 0x07, 0x00, 0x02, 0x00, 0x7B]);
        match parse_message(&bytes) {
            Err(CodecError::BodyLengthMismatch {
                actual: 6,
                expected: 0,
            }) => {}
            other => panic!("expected BodyLengthMismatch, got {other:?}"),
        }
    }

    #[test]
    fn rejects_invalid_utf8_in_server_record() {
        // Server record (type 6) with body 0xFF 0xFE — invalid UTF-8 start byte.
        let bytes = vec![0x00, 0x06, 0x00, 0x02, 0xFF, 0xFE, 0x80, 0x00, 0x00, 0x00];
        match parse_message(&bytes) {
            Err(CodecError::InvalidUtf8) => {}
            other => panic!("expected InvalidUtf8, got {other:?}"),
        }
    }

    #[test]
    fn rejects_message_too_large() {
        let bytes = vec![0u8; MAX_MESSAGE_BYTES + 1];
        match parse_message(&bytes) {
            Err(CodecError::MessageTooLarge { actual }) if actual == MAX_MESSAGE_BYTES + 1 => {}
            other => panic!("expected MessageTooLarge, got {other:?}"),
        }
    }

    #[test]
    fn rejects_wrong_length_error_record() {
        // Error record (type 2, critical) with body length 4 instead of 2.
        let bytes = vec![
            0x80, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00,
        ];
        match parse_message(&bytes) {
            Err(CodecError::BodyLengthMismatch {
                actual: 4,
                expected: 2,
            }) => {}
            other => panic!("expected BodyLengthMismatch, got {other:?}"),
        }
    }

    /// `serialize_message` accepts (and the round-trip test above
    /// already exercises) a properly terminated record list. Pin
    /// that the EOM-terminator assertion does *not* fire on a well-
    /// formed input — otherwise the `assert!` would produce a noisy
    /// false positive every time the codec is exercised in the test
    /// suite.
    #[test]
    fn serialize_message_accepts_terminated_input() {
        let msg = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(true, RecordKind::EndOfMessage),
        ];
        let _ = serialize_message(&msg);
    }

    /// Calling `serialize_message` without an `EndOfMessage`
    /// terminator must panic at the offending call site rather than
    /// producing a malformed message that would only fail at parse
    /// time on the peer. The check uses `assert!` (not
    /// `debug_assert!`) so the guard is load-bearing in both debug
    /// and release builds — otherwise a release-mode regression in
    /// any caller (or a future caller that builds the record list
    /// dynamically) would silently emit a malformed wire packet.
    /// This test runs in both build profiles to pin that contract.
    #[test]
    #[should_panic(expected = "RFC 8915 §4")]
    fn serialize_message_panics_when_eom_terminator_missing() {
        let msg = vec![rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4]))];
        let _ = serialize_message(&msg);
    }

    /// An empty record slice has no last record at all; the same
    /// terminator-required invariant must hold there too. Same
    /// release-build coverage rationale as
    /// [`serialize_message_panics_when_eom_terminator_missing`].
    #[test]
    #[should_panic(expected = "RFC 8915 §4")]
    fn serialize_message_panics_on_empty_input() {
        let _ = serialize_message(&[]);
    }

    /// Per-variant body-length boundary for the NTPv4-Port record
    /// (RFC 8915 §4.1.8 — 2-octet u16 port). A buggy or hostile
    /// server emitting a 1- or 3-byte body around the fixed 2-byte
    /// payload must surface `BodyLengthMismatch` from
    /// `decode_u16_scalar` rather than silently truncating or
    /// over-reading; a body declared longer than the bytes actually
    /// present must surface `BodyOverflow` from the message-frame
    /// boundary check before `decode_kind` is even consulted. Mirrors
    /// `ntpd-rs ntp-proto/src/nts/record.rs::test_port` (v1.7.2).
    #[test]
    fn rejects_wrong_length_port_record() {
        // body_len declared as 1, body present is `[0x00]`.
        let bytes = vec![0x00, record_type::NTPV4_PORT as u8, 0x00, 0x01, 0x00];
        match parse_message(&bytes) {
            Err(CodecError::BodyLengthMismatch {
                actual: 1,
                expected: 2,
            }) => {}
            other => panic!("len-1 Port: expected BodyLengthMismatch, got {other:?}"),
        }

        // body_len declared as 3, body present is `[0x00, 0x7B, 0x05]`.
        let bytes = vec![
            0x00,
            record_type::NTPV4_PORT as u8,
            0x00,
            0x03,
            0x00,
            0x7B,
            0x05,
        ];
        match parse_message(&bytes) {
            Err(CodecError::BodyLengthMismatch {
                actual: 3,
                expected: 2,
            }) => {}
            other => panic!("len-3 Port: expected BodyLengthMismatch, got {other:?}"),
        }

        // body_len declared as 2, only 1 byte present after header.
        let bytes = vec![0x00, record_type::NTPV4_PORT as u8, 0x00, 0x02, 0x00];
        match parse_message(&bytes) {
            Err(CodecError::BodyOverflow {
                claimed: 2,
                remaining: 1,
            }) => {}
            other => panic!("under-supplied Port: expected BodyOverflow, got {other:?}"),
        }
    }

    /// Per-variant body-length boundary for the Warning record
    /// (RFC 8915 §4.1.4 — 2-octet u16 warning code). Same shape as
    /// `rejects_wrong_length_port_record`; both critical (`0x80, 3`)
    /// and non-critical (`0x00, 3`) wire encodings must trip the
    /// same `BodyLengthMismatch` so the codec layer's per-variant
    /// length check is independent of the critical-bit setting.
    /// Mirrors `ntpd-rs ntp-proto/src/nts/record.rs::test_warning`
    /// (v1.7.2).
    #[test]
    fn rejects_wrong_length_warning_record() {
        for first_byte in [0x80u8, 0x00u8] {
            // body_len 1.
            let bytes = vec![first_byte, record_type::WARNING as u8, 0x00, 0x01, 0x00];
            match parse_message(&bytes) {
                Err(CodecError::BodyLengthMismatch {
                    actual: 1,
                    expected: 2,
                }) => {}
                other => panic!(
                    "Warning(critical={}, len=1): expected BodyLengthMismatch, got {other:?}",
                    first_byte == 0x80,
                ),
            }

            // body_len 3.
            let bytes = vec![
                first_byte,
                record_type::WARNING as u8,
                0x00,
                0x03,
                0x12,
                0x34,
                0x56,
            ];
            match parse_message(&bytes) {
                Err(CodecError::BodyLengthMismatch {
                    actual: 3,
                    expected: 2,
                }) => {}
                other => panic!(
                    "Warning(critical={}, len=3): expected BodyLengthMismatch, got {other:?}",
                    first_byte == 0x80,
                ),
            }
        }
    }

    /// Per-variant boundary for NewCookie (RFC 8915 §4.1.6). The
    /// record carries an opaque cookie blob with no fixed payload
    /// width, so the codec has no per-variant length to check; the
    /// only failure mode at the codec layer is a body declared longer
    /// than the bytes actually present, which must surface
    /// `BodyOverflow` from the message-frame check before
    /// `decode_kind` is consulted. Mirrors
    /// `ntpd-rs ntp-proto/src/nts/record.rs::test_new_cookie`
    /// (v1.7.2).
    #[test]
    fn rejects_truncated_new_cookie_record() {
        // critical=true, type=NEW_COOKIE(5), body_len=3, body present
        // is only `[0x01, 0x02]` (2 bytes).
        let bytes = vec![0x80, record_type::NEW_COOKIE as u8, 0x00, 0x03, 0x01, 0x02];
        match parse_message(&bytes) {
            Err(CodecError::BodyOverflow {
                claimed: 3,
                remaining: 2,
            }) => {}
            other => panic!("under-supplied NewCookie: expected BodyOverflow, got {other:?}"),
        }
    }

    /// Per-variant boundary for the NTPv4-Server record
    /// (RFC 8915 §4.1.7 — variable-length UTF-8 hostname). The codec
    /// has no per-variant length to enforce (the UTF-8 check fires
    /// only on a non-UTF-8 body, covered by
    /// `rejects_invalid_utf8_in_server_record`), so the only failure
    /// mode at the codec layer is a body declared longer than the
    /// bytes actually present, which must surface `BodyOverflow`
    /// from the message-frame check. Mirrors
    /// `ntpd-rs ntp-proto/src/nts/record.rs::test_server` (v1.7.2).
    #[test]
    fn rejects_truncated_server_record() {
        // critical=true, type=NTPV4_SERVER(6), body_len=5, body
        // present is only `[b'h', b'e', b'l']` (3 bytes).
        let bytes = vec![
            0x80,
            record_type::NTPV4_SERVER as u8,
            0x00,
            0x05,
            b'h',
            b'e',
            b'l',
        ];
        match parse_message(&bytes) {
            Err(CodecError::BodyOverflow {
                claimed: 5,
                remaining: 3,
            }) => {}
            other => panic!("under-supplied Server: expected BodyOverflow, got {other:?}"),
        }
    }

    /// The codec layer must preserve the critical bit verbatim for
    /// every known record type, regardless of whether the variant
    /// carries an RFC 8915 §4.1 critical-bit requirement. The
    /// `validate_response` layer in `nts::ke` is the one that rejects
    /// `NextProtocol`/`AeadAlgorithm` records without the critical
    /// bit set (RFC 8915 §4.1.2 / §4.1.5); the codec itself must
    /// tolerate either setting and round-trip it faithfully so the
    /// validation logic can see the actual on-wire bit. A future edit
    /// that pushes the critical-bit policy down into the codec would
    /// silently re-classify a non-compliant server response as a
    /// codec-level failure rather than a protocol-level one, losing
    /// the attribution; this parameterised round-trip pins the
    /// separation. Mirrors the implicit "parser tolerates either
    /// critical-bit setting on known record types" property exercised
    /// across `ntpd-rs ntp-proto/src/nts/record.rs::test_*` (v1.7.2).
    #[test]
    fn parser_tolerates_either_critical_bit_per_known_variant() {
        // Per-variant minimal-body samples for each non-EOM record
        // type. Each kind is paired with both critical settings;
        // EndOfMessage is exercised separately below because it
        // doubles as the message terminator.
        let kinds: Vec<RecordKind> = vec![
            RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4]),
            RecordKind::Error(ErrorCode::InternalServerError),
            RecordKind::Warning(WarningCode::Unknown(0)),
            RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            RecordKind::NewCookie(vec![0xAB; 4]),
            RecordKind::Server("h".to_owned()),
            RecordKind::Port(123),
        ];
        for kind in kinds {
            for critical in [true, false] {
                let msg = vec![
                    rec(critical, kind.clone()),
                    rec(true, RecordKind::EndOfMessage),
                ];
                let bytes = serialize_message(&msg);
                let parsed = parse_message(&bytes).unwrap_or_else(|e| {
                    panic!("kind={kind:?} critical={critical}: parse failed with {e:?}",)
                });
                assert_eq!(
                    parsed.len(),
                    2,
                    "kind={kind:?} critical={critical}: expected 2 records, got {}",
                    parsed.len(),
                );
                assert_eq!(
                    parsed[0].critical, critical,
                    "kind={kind:?}: critical bit not round-tripped",
                );
                assert_eq!(
                    parsed[0].kind, kind,
                    "kind={kind:?}: payload not round-tripped under critical={critical}",
                );
            }
        }

        // EndOfMessage as the sole record under both critical
        // settings. RFC 8915 §4 says the EOM record SHOULD have the
        // critical bit set; the codec must preserve whichever bit the
        // peer sent so the validation layer can apply policy.
        for critical in [true, false] {
            let msg = vec![rec(critical, RecordKind::EndOfMessage)];
            let bytes = serialize_message(&msg);
            let parsed = parse_message(&bytes).unwrap_or_else(|e| {
                panic!("EndOfMessage critical={critical}: parse failed with {e:?}",)
            });
            assert_eq!(parsed.len(), 1);
            assert_eq!(parsed[0].critical, critical);
            assert_eq!(parsed[0].kind, RecordKind::EndOfMessage);
        }
    }

    /// Pin the `u16` ⇄ `ErrorCode` round-trip across the three
    /// IANA-registered codes (RFC 8915 §4.1.3 — 0/1/2) plus an
    /// out-of-registry sample and the `u16` ceiling, both routed
    /// through the `Unknown(u16)` wrapper variant (not a spec'd
    /// code — the IANA registry stops at 2). The round-trip itself
    /// proves encoder/decoder symmetry and `Unknown` payload
    /// preservation. The named-variant spot checks below pin the
    /// asymmetric failure mode in the two `From` impls:
    /// `From<ErrorCode> for u16` is an exhaustive match that
    /// refuses to compile if a future variant is added without an
    /// arm (good), but `From<u16> for ErrorCode` ends in a
    /// catch-all `other => Self::Unknown(other)` arm that would
    /// silently route a future spec'd code (e.g. IANA code 3)
    /// through `Unknown` until a matching arm is added — so the
    /// spot checks for 0/1/2 must trip if any of those mappings
    /// regresses.
    #[test]
    fn error_code_round_trips_all_iana_codes() {
        for code in [0u16, 1, 2, 0xBEEF, 0xFFFF] {
            let typed = ErrorCode::from(code);
            assert_eq!(u16::from(typed), code, "round-trip lost code {code}");
            assert_eq!(typed.as_u16(), code, "as_u16() disagreed for {code}");
        }
        // Spot-check the named-variant assignment matches RFC 8915
        // §4.1.3's numbering directly so a transposition (e.g.
        // BadRequest <-> InternalServerError) fails immediately.
        assert_eq!(ErrorCode::from(0), ErrorCode::UnrecognizedCriticalRecord);
        assert_eq!(ErrorCode::from(1), ErrorCode::BadRequest);
        assert_eq!(ErrorCode::from(2), ErrorCode::InternalServerError);
        assert_eq!(ErrorCode::from(3), ErrorCode::Unknown(3));
    }

    /// Pin the `Display` rendering of every `ErrorCode` variant.
    /// Logs and `KeError::ServerError`'s `Display` rely on this; a
    /// rename of any spec'd variant must trip this test before it
    /// silently changes the diagnostic surface.
    #[test]
    fn error_code_display_matches_iana_names() {
        assert_eq!(
            ErrorCode::UnrecognizedCriticalRecord.to_string(),
            "UnrecognizedCriticalRecord"
        );
        assert_eq!(ErrorCode::BadRequest.to_string(), "BadRequest");
        assert_eq!(
            ErrorCode::InternalServerError.to_string(),
            "InternalServerError"
        );
        assert_eq!(ErrorCode::Unknown(0xBEEF).to_string(), "Unknown(48879)");
    }

    /// Symmetric round-trip pin for `WarningCode`. The IANA registry
    /// is empty as of RFC 8915 so every code lands in `Unknown`
    /// today; this test exists so a future named-variant promotion
    /// has a single place to extend and a single place to assert
    /// the existing catch-all behaviour was not regressed.
    #[test]
    fn warning_code_round_trips_unknown_payload() {
        for code in [0u16, 1, 0x1234, 0xFFFF] {
            let typed = WarningCode::from(code);
            assert_eq!(u16::from(typed), code);
            assert_eq!(typed.as_u16(), code);
            assert_eq!(typed, WarningCode::Unknown(code));
        }
        assert_eq!(WarningCode::Unknown(0x1234).to_string(), "Unknown(4660)");
    }

    /// Wire-level pin: an Error record carrying each IANA-registered
    /// code (and one out-of-registry code) round-trips through the
    /// codec without dropping the typed wrapper. Catches a decoder
    /// that forgets to wrap (or an encoder that double-wraps).
    #[test]
    fn error_record_round_trips_through_codec() {
        for code in [
            ErrorCode::UnrecognizedCriticalRecord,
            ErrorCode::BadRequest,
            ErrorCode::InternalServerError,
            ErrorCode::Unknown(0xBEEF),
        ] {
            let msg = vec![
                rec(true, RecordKind::Error(code)),
                rec(true, RecordKind::EndOfMessage),
            ];
            let bytes = serialize_message(&msg);
            let parsed = parse_message(&bytes)
                .unwrap_or_else(|e| panic!("code={code:?}: parse failed with {e:?}"));
            assert_eq!(parsed[0].kind, RecordKind::Error(code));
        }
    }
}
