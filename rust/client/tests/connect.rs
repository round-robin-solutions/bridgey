//! Connect away from home between two session clients: after a pairing on the local network they set up a pair secret
//! (connect.setup) and learn each other's addresses (connect.addresses); with local network connections cut, the core's
//! node brings up a QUIC tunnel to a learned address and the session reconnects over it (bridgey-auth-v2).

mod common;

use bridgey_core::Event;
use common::{pair, Peer};
use std::time::{Duration, Instant};

fn away_ready(p: &Peer) -> bool {
    p.client.snapshot()["devices"].as_array().is_some_and(|d| d.iter().any(|x| x["away"] == true))
}

#[test]
fn devices_reconnect_over_a_tunnel_when_the_local_network_is_gone() {
    let (pc, phone) = (Peer::new("Windows PC"), Peer::new("Test phone"));
    pc.client.set_connect(true, None).unwrap();
    phone.client.set_connect(true, None).unwrap();
    pair(&pc, &phone);
    let deadline = Instant::now() + Duration::from_secs(20);
    while !(away_ready(&pc) && away_ready(&phone)) {
        assert!(Instant::now() < deadline, "the pair secret was not set up: {} / {}", pc.client.snapshot(), phone.client.snapshot());
        std::thread::sleep(Duration::from_millis(200));
    }
    assert_eq!(pc.client.snapshot()["connect"]["state"], "disabled", "no control service: learned addresses only");

    // Cut the local network: the TCP session closes and only a tunnel can bring the devices back together.
    pc.clear();
    phone.client.set_lan_for_tests(false);
    pc.client.set_lan_for_tests(false);
    pc.wait("the local session dropped", |e| matches!(e, Event::Disconnected { .. }).then_some(()));
    pc.wait("back over a tunnel", |e| matches!(e, Event::Connected { .. }).then_some(()));
    phone.wait("back over a tunnel at the phone", |e| matches!(e, Event::Features { .. }).then_some(()));
    std::thread::sleep(Duration::from_millis(500));
    phone.clear();
    pc.client.send_clipboard(&phone.id(), "over the tunnel ✓").unwrap();
    let text = phone.wait("text over the tunnel", |e| match e {
        Event::Clipboard { text, .. } => Some(text.clone()),
        _ => None,
    });
    assert_eq!(text, "over the tunnel ✓");
    assert_eq!(pc.client.snapshot()["connect"]["tunnels"], 1, "the session runs on a tunnel");
    pc.client.set_connect(false, None).unwrap();
    assert_eq!(pc.client.snapshot()["connect"]["state"], "off");
    pc.stop();
    phone.stop();
}
