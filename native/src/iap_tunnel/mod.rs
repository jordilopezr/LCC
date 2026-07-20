//! Native IAP TCP forwarding.
//!
//! Layers: `frame` (pure codec), `session` (WebSocket relay session),
//! `listener` (local TCP listener bridging sockets to sessions).

pub mod frame;
