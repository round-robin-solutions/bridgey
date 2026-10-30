//! Checks the warm relay's reclaim against one relay: a process allocates on a socket and dies without releasing
//! (simulated by dropping the allocation object), then a new process on the same socket ends that allocation
//! with its credentials and allocates again. Also checks that two allocations on one relay reach each other
//! (the pool permission for the relay's own address). The secret never leaves this machine.
//!
//! TURN_SECRET=... cargo run --example reclaim_check -- relay-sg.roundrobin.in:3478

use bridgey_connect::mux::{Mux, Path, Via};
use bridgey_connect::turn::{self, Allocation};
use std::time::{Duration, Instant};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let target = std::env::args().nth(1).expect("host:port");
    let secret = std::env::var("TURN_SECRET").expect("TURN_SECRET");
    let server = tokio::net::lookup_host(&target).await.expect("resolve").find(|a| a.is_ipv4()).expect("an IPv4 address");
    let server = bridgey_connect::addrs::canonical(server);
    let expiry = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 600;
    let user = bridgey_connect_proto::rdv::warm_username(secret.as_bytes(), expiry, "reclaim-check");
    let pass = bridgey_connect_proto::rdv::turn_rest_credential(secret.as_bytes(), &user);
    let mux = Mux::bind(0).expect("udp");
    let first = Allocation::allocate(mux.clone(), server, "check", &user, &pass).await.expect("first allocation");
    let realm = first.realm();
    println!("first allocation {}", first.relayed);
    // The process dies: nothing is released.
    std::mem::forget(first);
    let again = Allocation::allocate_with(mux.clone(), server, "check", &user, &pass, Some(realm.clone())).await;
    println!("allocate again without reclaim: {}", again.as_ref().err().cloned().unwrap_or_else(|| "OK (unexpected)".into()));
    let started = Instant::now();
    let released = turn::release_left_behind(mux.clone(), server, &user, &pass, Some(realm.clone())).await;
    println!("reclaim (refresh 0 with its credentials): {released:?} in {} ms", started.elapsed().as_millis());
    let started = Instant::now();
    let mut second = Allocation::allocate_with(mux.clone(), server, "check", &user, &pass, Some(realm.clone())).await;
    while second.is_err() && started.elapsed() < Duration::from_secs(5) {
        tokio::time::sleep(Duration::from_millis(20)).await;
        second = Allocation::allocate_with(mux.clone(), server, "check", &user, &pass, Some(realm.clone())).await;
    }
    match &second {
        Ok(a) => println!("allocate after reclaim: OK {} in {} ms", a.relayed, started.elapsed().as_millis()),
        Err(e) => println!("allocate after reclaim: {e}"),
    }
    // Relay to relay: a second socket's allocation on the same relay, both permitting the relay's own address.
    let Ok(a) = second else { std::process::exit(1) };
    let mux_b = Mux::bind(0).expect("udp");
    let user_b = bridgey_connect_proto::rdv::warm_username(secret.as_bytes(), expiry, "reclaim-check-b");
    let b = Allocation::allocate(mux_b.clone(), server, "check", &user_b, &bridgey_connect_proto::rdv::turn_rest_credential(secret.as_bytes(), &user_b)).await.expect("b");
    println!("pool permission a: {:?}, b: {:?}", a.permit(&[server.ip()]).await, b.permit(&[server.ip()]).await);
    let ping = bridgey_connect::stun::Message::request(bridgey_connect::stun::BINDING);
    let reply = mux.transact(Path { via: Via::Turn(server), remote: b.relayed }, &ping.encode(None, true), ping.txid, 3, false).await;
    println!("a's relay to b's relayed address (no channel, Send indication): {}", if reply.is_some() { "answered" } else { "no answer (b does not answer STUN, expected)" });
    a.release().await;
    b.release().await;
    tokio::time::sleep(Duration::from_millis(10)).await;
}
