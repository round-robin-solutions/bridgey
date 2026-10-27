//! Connect anywhere core (docs/connect-anywhere.md): routes, ICE, TURN, the QUIC tunnel and the
//! rendezvous client, used by the Android and Mac apps through a small JSON command interface.

pub mod addrs;
pub mod ffi;
pub mod ice;
pub mod mux;
pub mod node;
pub mod quic;
pub mod rdv_client;
pub mod stun;
pub mod turn;
