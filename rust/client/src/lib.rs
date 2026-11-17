//! Bridgey session client (`bridgey_core`): what a new platform needs to be a Bridgey device next to the
//! Android and Mac apps. Discovery, protocol 2 pairing, the trust store, the encrypted session, the strict
//! frame codec, feature negotiation and clipboard text, reported as events through a C ABI
//! (`include/bridgey_core.h`, docs/session-client.md).
//!
//! The codec and cryptography are the ones the agent CLI has spoken with both apps since 0.10; the CLI now
//! uses them from here.

pub mod client;
pub mod codes;
pub mod crypto;
#[cfg(feature = "mdns")]
mod discovery;
pub mod events;
pub mod fast;
pub mod features;
pub mod ffi;
pub mod notifications;
pub mod quick;
pub mod session;
pub mod transfer;
pub mod trust;
#[cfg(test)]
mod vectors;
pub mod wire;

pub use client::{Client, ClientError, Config};
pub use events::{Event, Next, SendStatus};
pub use features::FeatureMap;
pub use trust::{FileStorage, MemoryStorage, Storage};

/// The C ABI's version. Bumped on any incompatible change to `include/bridgey_core.h`.
pub const ABI_VERSION: u32 = ffi::BRIDGEY_ABI_VERSION;
