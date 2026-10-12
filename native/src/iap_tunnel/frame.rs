//! IAP relay subprotocol codec. Pure functions, no I/O.
//!
//! Wire format (big-endian):
//!   DATA / CONNECT_SUCCESS_SID / unknown: tag(u16) + len(u32) + payload
//!   ACK / RECONNECT_SUCCESS_ACK:          tag(u16) + value(u64)

pub const MAX_DATA_FRAME_SIZE: usize = 16384;

pub const TAG_CONNECT_SUCCESS_SID: u16 = 0x0001;
pub const TAG_RECONNECT_SUCCESS_ACK: u16 = 0x0002;
pub const TAG_DATA: u16 = 0x0004;
pub const TAG_ACK: u16 = 0x0007;

const TAG_LEN: usize = 2;
const LEN_LEN: usize = 4;
const U64_LEN: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    ConnectSuccessSid(Vec<u8>),
    ReconnectSuccessAck(u64),
    Data(Vec<u8>),
    Ack(u64),
    /// A tag we do not model. Consumed so the stream stays in sync.
    Unknown { tag: u16 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    PayloadTooLarge { len: usize },
}

/// Split a payload into chunks that each fit in one DATA frame.
pub fn chunks(payload: &[u8]) -> impl Iterator<Item = &[u8]> {
    payload.chunks(MAX_DATA_FRAME_SIZE)
}

/// Encode one DATA frame. Panics in debug if the payload is oversized;
/// callers that cannot guarantee the size should use [`encode_data_checked`].
pub fn encode_data(payload: &[u8]) -> Vec<u8> {
    debug_assert!(payload.len() <= MAX_DATA_FRAME_SIZE);
    let mut out = Vec::with_capacity(TAG_LEN + LEN_LEN + payload.len());
    out.extend_from_slice(&TAG_DATA.to_be_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

pub fn encode_data_checked(payload: &[u8]) -> Result<Vec<u8>, FrameError> {
    if payload.len() > MAX_DATA_FRAME_SIZE {
        return Err(FrameError::PayloadTooLarge { len: payload.len() });
    }
    Ok(encode_data(payload))
}

pub fn encode_ack(total_bytes: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(TAG_LEN + U64_LEN);
    out.extend_from_slice(&TAG_ACK.to_be_bytes());
    out.extend_from_slice(&total_bytes.to_be_bytes());
    out
}

/// Decode the first frame in `buf`.
///
/// Returns `Ok(None)` when `buf` does not yet hold a complete frame — the
/// caller should read more bytes and retry with the same buffer.
pub fn decode(buf: &[u8]) -> Result<Option<(Frame, usize)>, FrameError> {
    if buf.len() < TAG_LEN {
        return Ok(None);
    }
    let tag = u16::from_be_bytes([buf[0], buf[1]]);
    let rest = &buf[TAG_LEN..];

    match tag {
        TAG_ACK | TAG_RECONNECT_SUCCESS_ACK => {
            if rest.len() < U64_LEN {
                return Ok(None);
            }
            let mut value = [0u8; U64_LEN];
            value.copy_from_slice(&rest[..U64_LEN]);
            let value = u64::from_be_bytes(value);
            let frame = if tag == TAG_ACK {
                Frame::Ack(value)
            } else {
                Frame::ReconnectSuccessAck(value)
            };
            Ok(Some((frame, TAG_LEN + U64_LEN)))
        }
        _ => {
            if rest.len() < LEN_LEN {
                return Ok(None);
            }
            let len = u32::from_be_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
            if len > MAX_DATA_FRAME_SIZE {
                return Err(FrameError::PayloadTooLarge { len });
            }
            let body = &rest[LEN_LEN..];
            if body.len() < len {
                return Ok(None);
            }
            let consumed = TAG_LEN + LEN_LEN + len;
            let payload = body[..len].to_vec();
            let frame = match tag {
                TAG_DATA => Frame::Data(payload),
                TAG_CONNECT_SUCCESS_SID => Frame::ConnectSuccessSid(payload),
                other => Frame::Unknown { tag: other },
            };
            Ok(Some((frame, consumed)))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_frame_round_trip() {
        let encoded = encode_data(b"hola");
        // tag(2) + len(4) + payload(4)
        assert_eq!(encoded.len(), 10);
        assert_eq!(&encoded[0..2], &[0x00, 0x04]);
        assert_eq!(&encoded[2..6], &[0, 0, 0, 4]);

        let (frame, consumed) = decode(&encoded).unwrap().unwrap();
        assert_eq!(consumed, 10);
        assert_eq!(frame, Frame::Data(b"hola".to_vec()));
    }

    #[test]
    fn ack_frame_round_trip() {
        let encoded = encode_ack(70_000);
        assert_eq!(encoded.len(), 10); // tag(2) + u64(8)
        assert_eq!(&encoded[0..2], &[0x00, 0x07]);

        let (frame, consumed) = decode(&encoded).unwrap().unwrap();
        assert_eq!(consumed, 10);
        assert_eq!(frame, Frame::Ack(70_000));
    }

    #[test]
    fn connect_success_sid_is_decoded() {
        let mut buf = vec![0x00, 0x01, 0, 0, 0, 3];
        buf.extend_from_slice(b"abc");
        let (frame, consumed) = decode(&buf).unwrap().unwrap();
        assert_eq!(consumed, 9);
        assert_eq!(frame, Frame::ConnectSuccessSid(b"abc".to_vec()));
    }

    #[test]
    fn reconnect_success_ack_is_decoded() {
        let mut buf = vec![0x00, 0x02];
        buf.extend_from_slice(&1234u64.to_be_bytes());
        let (frame, consumed) = decode(&buf).unwrap().unwrap();
        assert_eq!(consumed, 10);
        assert_eq!(frame, Frame::ReconnectSuccessAck(1234));
    }

    #[test]
    fn truncated_input_asks_for_more_bytes() {
        // Header says 4 bytes of payload but only 2 are present.
        let buf = vec![0x00, 0x04, 0, 0, 0, 4, b'h', b'o'];
        assert_eq!(decode(&buf).unwrap(), None);
        // Not even a full tag.
        assert_eq!(decode(&[0x00]).unwrap(), None);
        // Tag present, length truncated.
        assert_eq!(decode(&[0x00, 0x04, 0, 0]).unwrap(), None);
    }

    #[test]
    fn unknown_tag_is_reported_and_consumed_as_length_prefixed() {
        let buf = vec![0x00, 0x63, 0, 0, 0, 1, 0xFF];
        let (frame, consumed) = decode(&buf).unwrap().unwrap();
        assert_eq!(frame, Frame::Unknown { tag: 0x0063 });
        assert_eq!(consumed, 7);
    }

    #[test]
    fn decode_rejects_oversized_declared_length() {
        let mut buf = vec![0x00, 0x04];
        buf.extend_from_slice(&((MAX_DATA_FRAME_SIZE + 1) as u32).to_be_bytes());
        // No payload bytes needed: the length check must reject before
        // waiting for the (huge) body to arrive.
        assert_eq!(
            decode(&buf),
            Err(FrameError::PayloadTooLarge { len: MAX_DATA_FRAME_SIZE + 1 })
        );
    }

    #[test]
    fn oversized_payload_is_rejected() {
        let big = vec![0u8; MAX_DATA_FRAME_SIZE + 1];
        assert!(matches!(
            encode_data_checked(&big),
            Err(FrameError::PayloadTooLarge { .. })
        ));
    }

    #[test]
    fn chunking_splits_at_max_frame_size() {
        let payload = vec![7u8; MAX_DATA_FRAME_SIZE * 2 + 5];
        let chunks: Vec<&[u8]> = chunks(&payload).collect();
        assert_eq!(chunks.len(), 3);
        assert_eq!(chunks[0].len(), MAX_DATA_FRAME_SIZE);
        assert_eq!(chunks[1].len(), MAX_DATA_FRAME_SIZE);
        assert_eq!(chunks[2].len(), 5);
    }
}
