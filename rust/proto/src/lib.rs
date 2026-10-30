//! Connect anywhere, shared by the core and the control service (docs/connect-anywhere.md).
//!
//! Every wire string here is unbranded (`bridgey-*-v1`) so the protocol can be offered upstream.

pub mod b64;
pub mod derive;
pub mod rdv;
pub mod seal;
pub mod signal;
pub mod vectors;
