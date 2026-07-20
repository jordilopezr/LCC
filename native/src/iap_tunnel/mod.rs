//! Native IAP TCP forwarding.
//!
//! Layers: `frame` (pure codec), `session` (WebSocket relay session),
//! `listener` (local TCP listener bridging sockets to sessions).

pub mod error;
pub mod frame;
pub mod listener;
pub mod session;

pub use error::TunnelError;
pub use listener::{start, NativeTunnel};
pub use session::TunnelTarget;
