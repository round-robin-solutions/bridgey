//! Tests and the scripted peer only: this device answers phone requests as a phone would, with canned conversations,
//! calls, files and a test screen (`Client::simulate_phone_for_tests`). Never used by the apps.
//!
//! Each area adds its own part here, next to its module, so the desktop side is tested against a phone without one.

use crate::client::Inner;
use crate::phone::Incoming;

/// The kinds a desktop sends that a simulated phone takes.
pub(crate) fn incoming(kind: &str) -> Option<Incoming> {
    crate::sms::sim_incoming(kind).or_else(|| crate::calls::sim_incoming(kind)).or_else(|| crate::phone_files::sim_incoming(kind))
}

/// A request from the desktop; true when it was a simulated phone's to answer.
pub(crate) fn receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) -> bool {
    crate::sms::sim_receive(inner, device_id, kind, plain)
        || crate::calls::sim_receive(inner, device_id, kind, plain)
        || crate::phone_files::sim_receive(inner, device_id, kind, plain)
}
