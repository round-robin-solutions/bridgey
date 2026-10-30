//! Checks one relay from outside: a TURN allocation with TURN REST credentials, then its release.
//! The secret never leaves the machine that runs this; pass it in the environment.
//!
//! TURN_SECRET=... cargo run --example turn_check -- relay-eu.roundrobin.in:3478

use bridgey_connect::mux::Mux;
use bridgey_connect::turn::{self, Allocation};
use std::time::{Duration, Instant};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let target = std::env::args().nth(1).expect("host:port");
    let secret = std::env::var("TURN_SECRET").expect("TURN_SECRET");
    let server = tokio::net::lookup_host(&target).await.expect("resolve").find(|a| a.is_ipv4()).expect("an IPv4 address");
    let mux = Mux::bind(0).expect("udp");
    let started = Instant::now();
    let reflexive = turn::reflexive(&mux, server).await;
    let stun_ms = started.elapsed().as_millis();
    let expiry = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 600;
    let (user, pass) = bridgey_connect_proto::rdv::turn_rest_credentials(secret.as_bytes(), expiry, "turncheckAAAAAAAAAAAAA", 0);
    let started = Instant::now();
    match Allocation::allocate(mux.clone(), server, "check", &user, &pass).await {
        Ok(allocation) => {
            let ms = started.elapsed().as_millis();
            let bound = allocation.bind(allocation.relayed).await.is_ok();
            allocation.release().await;
            println!("{target}: STUN {} in {stun_ms} ms; allocation OK in {ms} ms, relayed {} (lifetime {:?}), channel bind {bound}, released",
                if reflexive.is_some() { "answered" } else { "no answer" }, allocation.relayed, allocation.lifetime);
        }
        Err(e) => {
            println!("{target}: allocation FAILED: {e}");
            std::process::exit(1);
        }
    }
    let wrong = Allocation::allocate(mux, server, "check", &user, "wrong").await;
    println!("{target}: wrong credential refused: {}", wrong.is_err());
    tokio::time::sleep(Duration::from_millis(10)).await;
}
