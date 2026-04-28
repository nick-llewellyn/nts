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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecordKind {
    EndOfMessage,
    NextProtocol(Vec<u16>),
    Error(u16),
    Warning(u16),
    AeadAlgorithm(Vec<u16>),
    NewCookie(Vec<u8>),
    Server(String),
    Port(u16),
    Unknown { record_type: u16, body: Vec<u8> },
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
            RecordKind::Error(c) | RecordKind::Warning(c) | RecordKind::Port(c) => {
                out.extend_from_slice(&c.to_be_bytes());
            }
            RecordKind::NewCookie(b) | RecordKind::Unknown { body: b, .. } => {
                out.extend_from_slice(b);
            }
            RecordKind::Server(s) => out.extend_from_slice(s.as_bytes()),
        }
    }
}

/// Serialize a sequence of records, in order, into a single message.
///
/// Caller is responsible for placing `RecordKind::EndOfMessage` last;
/// the codec itself does not enforce framing semantics on the encode side.
///
/// In debug / test builds we additionally `debug_assert!` that the
/// terminator is present so a self-inflicted regression at any call
/// site (today: `nts::ke::build_request`) fails locally rather than
/// surfacing as an opaque parse error on the peer. The check costs
/// nothing in release builds (RFC 8915 §4 — every NTS-KE message ends
/// with an EndOfMessage record).
pub fn serialize_message(records: &[Record]) -> Vec<u8> {
    debug_assert!(
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
/// `EndOfMessage` body is required to be empty (RFC 8915 §4.1.5).
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
        record_type::ERROR => Ok(RecordKind::Error(decode_u16_scalar(body)?)),
        record_type::WARNING => Ok(RecordKind::Warning(decode_u16_scalar(body)?)),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(critical: bool, kind: RecordKind) -> Record {
        Record::new(critical, kind)
    }

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
            rec(false, RecordKind::Warning(0x1234)),
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
        // `serialize_message` because the new debug_assert in that helper
        // (RFC 8915 §4 EOM-terminator guard) would panic on the missing
        // terminator before we ever exercised the parser path under
        // test.
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

    /// `serialize_message` accepts (and the round-trip test above already
    /// exercises) a properly terminated record list. Pin that the
    /// debug-build assertion does *not* fire on a well-formed input —
    /// otherwise the assert would produce a noisy false positive every
    /// time the codec is exercised in the test suite.
    #[test]
    fn serialize_message_accepts_terminated_input() {
        let msg = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(true, RecordKind::EndOfMessage),
        ];
        let _ = serialize_message(&msg);
    }

    /// In debug builds, calling `serialize_message` without an
    /// `EndOfMessage` terminator must trip the `debug_assert!` and panic
    /// at the offending call site rather than producing a malformed
    /// message that would only fail at parse time on the peer. In
    /// release builds the assertion is compiled out, so the test is
    /// gated behind `debug_assertions`.
    #[cfg(debug_assertions)]
    #[test]
    #[should_panic(expected = "RFC 8915 §4")]
    fn serialize_message_debug_asserts_eom_terminator() {
        let msg = vec![rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4]))];
        let _ = serialize_message(&msg);
    }

    /// An empty record slice has no last record at all; the same
    /// terminator-required invariant must hold there too.
    #[cfg(debug_assertions)]
    #[test]
    #[should_panic(expected = "RFC 8915 §4")]
    fn serialize_message_debug_asserts_empty_input() {
        let _ = serialize_message(&[]);
    }
}
