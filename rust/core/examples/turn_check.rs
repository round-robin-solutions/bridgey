//! Checks one relay from outside: a TURN allocation, then its release. Secrets never leave the machine that runs this
//! and never go on a command line.
//!
//! An own (coturn) relay, with its TURN REST secret in the environment:
//!   TURN_SECRET=... cargo run --example turn_check -- relay-eu.roundrobin.in:3478
//!
//! A Cloudflare grant (the JSON TURN entry of a `generate-ice-servers` answer, `{"urls":[...],"username":...,
//! "credential":...}`, in a file only this user can read): allocations over UDP and over TLS on 443, a STUN check
//! relayed both ways between them, and a few seconds of paced traffic through the relay.
//!   TURN_GRANT_FILE=/path/grant.json cargo run --example turn_check -- --cloudflare

use bridgey_connect::mux::{Mux, Path, Via};
use bridgey_connect::stun::{self, Message};
use bridgey_connect::turn::{self, Allocation};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let target = std::env::args().nth(1).expect("host:port or --cloudflare");
    if target == "--cloudflare" {
        cloudflare().await;
        return;
    }
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

async fn cloudflare() {
    let path = std::env::var("TURN_GRANT_FILE").expect("TURN_GRANT_FILE");
    let grant: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).expect("grant file")).expect("grant JSON");
    let urls: Vec<String> = grant["urls"].as_array().expect("urls").iter().filter_map(|u| u.as_str().map(String::from)).collect();
    let user = grant["username"].as_str().expect("username").to_string();
    let pass = grant["credential"].as_str().expect("credential").to_string();
    let (host, port) = urls.iter().find_map(|u| turn::parse_udp_url(u)).expect("a UDP URL");
    let (tls_host, tls_port) = urls.iter().filter_map(|u| turn::parse_tls_url(u)).find(|(_, p)| *p == 443).expect("a TLS URL on 443");
    let server = tokio::net::lookup_host((host.as_str(), port)).await.expect("resolve").find(|a| a.is_ipv4()).expect("an IPv4 address");
    println!("Cloudflare TURN at {host}:{port} ({server}), TLS at {tls_host}:{tls_port}");

    // Over UDP: STUN, then an allocation.
    let a = Mux::bind(0).expect("udp");
    let started = Instant::now();
    let reflexive = turn::reflexive(&a, server).await;
    println!("UDP: STUN {} in {} ms", if reflexive.is_some() { "answered" } else { "did not answer" }, started.elapsed().as_millis());
    let started = Instant::now();
    let alloc_a = match Allocation::allocate(a.clone(), server, "cf", &user, &pass).await {
        Ok(x) => x,
        Err(e) => fail(&format!("UDP allocation FAILED: {e}")),
    };
    println!("UDP: allocation OK in {} ms, relayed {} (IPv4: {}), lifetime {:?}", started.elapsed().as_millis(), alloc_a.relayed, alloc_a.relayed.is_ipv4(), alloc_a.lifetime);

    // Over TLS on 443, on a second socket (Cloudflare checks the credential, the Web PKI checks Cloudflare).
    let b = Mux::bind(0).expect("udp");
    let started = Instant::now();
    let stream = match bridgey_connect::turn_tls::connect(&b, &tls_host, tls_port).await {
        Ok(key) => key,
        Err(e) => fail(&format!("TLS connection FAILED: {e}")),
    };
    let tls_ms = started.elapsed().as_millis();
    let alloc_b = match Allocation::allocate(b.clone(), stream, "cf", &user, &pass).await {
        Ok(x) => x,
        Err(e) => fail(&format!("TLS allocation FAILED: {e}")),
    };
    println!("TLS 443: connected in {tls_ms} ms, allocation OK in {} ms total, relayed {}", started.elapsed().as_millis(), alloc_b.relayed);

    // The permissions a warm allocation installs for the whole pool (each own relay, and Cloudflare's own address).
    let mut pool: Vec<std::net::IpAddr> = vec![server.ip()];
    for relay in ["relay-sg.roundrobin.in:3478", "relay-eu.roundrobin.in:3478"] {
        if let Some(addr) = tokio::net::lookup_host(relay).await.ok().and_then(|mut it| it.find(|a| a.is_ipv4())) {
            pool.push(addr.ip());
        }
    }
    // Cloudflare refuses its own address (and private ranges) with a 403 for the whole request, so the core asks for
    // the own relays only; each address alone shows which one it refuses.
    for ip in &pool {
        match alloc_a.permit(&[*ip]).await {
            Ok(()) => println!("Permission for {ip}: OK"),
            Err(e) => println!("Permission for {ip}: refused ({e})"),
        }
    }
    let own: Vec<std::net::IpAddr> = pool.iter().copied().filter(|ip| *ip != server.ip()).collect();
    match alloc_a.permit(&own).await {
        Ok(()) => println!("Pool permissions as the core asks for them ({} own relays): OK", own.len()),
        Err(e) => fail(&format!("pool permissions FAILED: {e}")),
    }

    // Each side lets the other's relayed address in, then a STUN check goes A -> relay -> relay -> B and back.
    alloc_a.permit(&[alloc_b.relayed.ip()]).await.unwrap_or_else(|e| fail(&format!("UDP permission FAILED: {e}")));
    alloc_b.permit(&[alloc_a.relayed.ip()]).await.unwrap_or_else(|e| fail(&format!("TLS permission FAILED: {e}")));
    answer_checks(&b, "chkb");
    answer_checks(&a, "chka");
    let rtt_ab = relayed_check(&a, alloc_a.server, alloc_b.relayed, "chkb").await;
    let rtt_ba = relayed_check(&b, alloc_b.server, alloc_a.relayed, "chka").await;
    match (rtt_ab, rtt_ba) {
        (Some(x), Some(y)) => println!("Relayed STUN check: UDP to TLS {} ms, TLS to UDP {} ms", x.as_millis(), y.as_millis()),
        _ => fail(&format!("relayed check FAILED (UDP to TLS {rtt_ab:?}, TLS to UDP {rtt_ba:?})")),
    }

    // A third socket over UDP, then channels, then 3 seconds of 1,200-byte datagrams from A to each, paced at
    // 40 Mbit/s as the core paces a Cloudflare allocation.
    let c = Mux::bind(0).expect("udp");
    let alloc_c = Allocation::allocate(c.clone(), server, "cf", &user, &pass).await.unwrap_or_else(|e| fail(&format!("second UDP allocation FAILED: {e}")));
    alloc_a.permit(&[alloc_c.relayed.ip()]).await.unwrap_or_else(|e| fail(&format!("UDP permission FAILED: {e}")));
    alloc_c.permit(&[alloc_a.relayed.ip()]).await.unwrap_or_else(|e| fail(&format!("UDP permission FAILED: {e}")));
    for (alloc, peer) in [(&alloc_a, alloc_b.relayed), (&alloc_b, alloc_a.relayed), (&alloc_a, alloc_c.relayed), (&alloc_c, alloc_a.relayed)] {
        alloc.bind(peer).await.unwrap_or_else(|e| fail(&format!("channel bind FAILED: {e}")));
    }
    a.set_pace(alloc_a.server, 40_000);
    paced(&a, alloc_a.server, &c, alloc_c.relayed, "UDP to UDP").await;
    paced(&a, alloc_a.server, &b, alloc_b.relayed, "UDP to TLS").await;

    let wrong = Allocation::allocate(Mux::bind(0).expect("udp"), server, "cf", &user, "wrong").await;
    println!("Wrong credential refused: {}", wrong.is_err());
    alloc_a.release().await;
    alloc_b.release().await;
    alloc_c.release().await;
    println!("Released the allocations");
}

/// Offers far more than the pace for 3 seconds from `from` through its relay to `peer`, and reports what arrived at `to`.
async fn paced(from: &Arc<Mux>, server: std::net::SocketAddr, to: &Arc<Mux>, peer: std::net::SocketAddr, label: &str) {
    let before = to.counters.relay_in.load(Ordering::Relaxed);
    let started = Instant::now();
    let path = Path { via: Via::Turn(server), remote: peer };
    let payload = vec![0x5au8; 1_196];
    let mut offered = 0u64;
    while started.elapsed() < Duration::from_secs(3) {
        for _ in 0..64 {
            if from.send_path(path, &payload).is_ok() {
                offered += payload.len() as u64;
            }
        }
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    let sending = started.elapsed().as_secs_f64();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let got = to.counters.relay_in.load(Ordering::Relaxed) - before;
    println!("Paced traffic {label}: {:.1} Mbit/s arrived ({:.1} MB offered, {:.1} MB arrived; pace 40 Mbit/s)", got as f64 * 8.0 / sending / 1e6, offered as f64 / 1e6, got as f64 / 1e6);
}

/// Answers STUN Binding checks for `ufrag` that reach this socket (through its relay), as an ICE agent would.
fn answer_checks(mux: &Arc<Mux>, ufrag: &str) {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    mux.register_ice(ufrag, tx);
    let mux = mux.clone();
    tokio::spawn(async move {
        while let Some(request) = rx.recv().await {
            let mut reply = Message::new(stun::BINDING, stun::SUCCESS, request.msg.txid);
            reply.add(stun::ATTR_XOR_MAPPED_ADDRESS, stun::encode_xor_address(request.path.remote, &request.msg.txid));
            mux.reply(request.path, &reply.encode(None, true));
        }
    });
}

/// A Binding check from `mux` through its relay at `server` to `peer`, answered by the agent for `ufrag` there.
async fn relayed_check(mux: &Arc<Mux>, server: std::net::SocketAddr, peer: std::net::SocketAddr, ufrag: &str) -> Option<Duration> {
    let mut m = Message::request(stun::BINDING);
    m.add(stun::ATTR_USERNAME, format!("{ufrag}:x").into_bytes());
    let started = Instant::now();
    mux.transact(Path { via: Via::Turn(server), remote: peer }, &m.encode(None, true), m.txid, 6, false).await.map(|_| started.elapsed())
}

fn fail(message: &str) -> ! {
    println!("{message}");
    std::process::exit(1)
}
