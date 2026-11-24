//! TURN over TLS (RFC 8656 over TLS-over-TCP), for networks that block UDP: Cloudflare listens on 443. One TLS stream
//! per relay carries the same STUN messages and ChannelData (padded to 4 bytes on a stream) that would go over UDP. The
//! mux sees the stream as a relay at a virtual address of its own, so allocations, permissions, channels and pacing
//! work unchanged; the relay still reaches the peer over UDP. The relay's certificate is checked against the Web PKI
//! (a Cloudflare grant carries no `spki`).

use crate::mux::Mux;
use std::net::SocketAddr;
use std::sync::{Arc, Weak};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

/// Messages waiting to be written: a few hundred ms of a paced allocation.
const STREAM_QUEUE: usize = 1_024;

/// Connects to `host:port` over TLS and hands the stream to the mux; returns the relay's virtual address there.
pub async fn connect(mux: &Arc<Mux>, host: &str, port: u16) -> Result<SocketAddr, String> {
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host, port)).await.map_err(|_| "relay name not found")?.collect();
    // Cloudflare relays only IPv4 to peers; reach it over IPv4 too where there is a choice.
    let addr = addrs.iter().find(|a| a.is_ipv4()).or(addrs.first()).copied().ok_or("relay name not found")?;
    let tcp = tokio::time::timeout(Duration::from_secs(5), tokio::net::TcpStream::connect(addr)).await.map_err(|_| "relay TLS: connect timed out")?.map_err(|e| format!("relay TLS: {}", e.kind()))?;
    let _ = tcp.set_nodelay(true);
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|_| "relay TLS: bad name")?;
    let tls = tokio::time::timeout(Duration::from_secs(5), tokio_rustls::TlsConnector::from(crate::rdv_client::tls_config()).connect(name, tcp))
        .await
        .map_err(|_| "relay TLS: handshake timed out")?
        .map_err(|e| format!("relay TLS: {e}"))?;
    Ok(attach(mux, tls))
}

/// Hands an established stream to the mux (TLS in use; any stream in tests).
pub fn attach<S: AsyncRead + AsyncWrite + Send + 'static>(mux: &Arc<Mux>, stream: S) -> SocketAddr {
    let key = mux.new_stream_key();
    let (reader, writer) = tokio::io::split(stream);
    let (tx, rx) = mpsc::channel(STREAM_QUEUE);
    mux.add_stream(key, tx);
    tokio::spawn(write_loop(writer, rx));
    tokio::spawn(read_loop(Arc::downgrade(mux), reader, key));
    key
}

async fn write_loop<W: AsyncWrite + Unpin>(mut writer: W, mut queue: mpsc::Receiver<Vec<u8>>) {
    while let Some(mut message) = queue.recv().await {
        pad(&mut message);
        if writer.write_all(&message).await.is_err() {
            break;
        }
        // Everything queued meanwhile goes out before the flush.
        while let Ok(mut more) = queue.try_recv() {
            pad(&mut more);
            if writer.write_all(&more).await.is_err() {
                return;
            }
        }
        if writer.flush().await.is_err() {
            break;
        }
    }
    let _ = writer.shutdown().await;
}

async fn read_loop<R: AsyncRead + Unpin>(mux: Weak<Mux>, mut reader: R, key: SocketAddr) {
    let mut buf: Vec<u8> = Vec::with_capacity(65_536);
    let mut chunk = vec![0u8; 32_768];
    'read: loop {
        let n = match reader.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        buf.extend_from_slice(&chunk[..n]);
        let mut start = 0;
        loop {
            match frame(&buf[start..]) {
                Ok(Some((len, padded))) => {
                    let Some(mux) = mux.upgrade() else { break 'read };
                    mux.receive_stream(&buf[start..start + len], key);
                    start += padded;
                }
                Ok(None) => break,
                // Not STUN or ChannelData: the stream is out of step and cannot recover.
                Err(()) => break 'read,
            }
        }
        buf.drain(..start);
    }
    if let Some(mux) = mux.upgrade() {
        mux.end_stream(key);
    }
}

/// ChannelData on a stream is padded to a multiple of 4 bytes (RFC 8656 section 12.5); STUN already is.
fn pad(message: &mut Vec<u8>) {
    if message.first().is_some_and(|b| (0x40..0x80).contains(b)) {
        message.resize(message.len().div_ceil(4) * 4, 0);
    }
}

/// The next message at the start of `buf`: its length and its length with padding, `None` while incomplete.
fn frame(buf: &[u8]) -> Result<Option<(usize, usize)>, ()> {
    if buf.len() < 4 {
        return Ok(None);
    }
    let body = usize::from(u16::from_be_bytes([buf[2], buf[3]]));
    let (len, padded) = match buf[0] {
        0x00..=0x03 => (20 + body, 20 + body),
        0x40..=0x7f => (4 + body, (4 + body).div_ceil(4) * 4),
        _ => return Err(()),
    };
    Ok((buf.len() >= padded).then_some((len, padded)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mux::{Path, Via};
    use crate::stun::{self, Message};
    use crate::turn::{self, Allocation};
    use bridgey_connect_proto::rdv::Msg;
    use std::sync::Arc;

    /// A TURN server at the far end of a stream: 401 with a realm and nonce to a request without credentials, then
    /// success to Allocate and CreatePermission whose MESSAGE-INTEGRITY checks out under the long-term key.
    async fn fake_relay(mut stream: tokio::io::DuplexStream, user: &'static str, pass: &'static str) {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4_096];
        loop {
            let n = stream.read(&mut chunk).await.unwrap_or(0);
            if n == 0 {
                return;
            }
            buf.extend_from_slice(&chunk[..n]);
            while let Ok(Some((len, padded))) = frame(&buf) {
                let asked = Message::decode(&buf[..len]).expect("STUN");
                buf.drain(..padded);
                let reply = match asked.string(stun::ATTR_USERNAME) {
                    None => {
                        let mut m = Message::new(asked.method, stun::ERROR, asked.txid);
                        m.add(stun::ATTR_ERROR_CODE, vec![0, 0, 4, 1]);
                        m.add(stun::ATTR_REALM, b"cf".to_vec());
                        m.add(stun::ATTR_NONCE, b"n0nce".to_vec());
                        m
                    }
                    Some(name) => {
                        assert_eq!(name, user);
                        assert!(asked.verify(&stun::long_term_key(user, "cf", pass)), "signed with the grant's credential");
                        let mut m = Message::new(asked.method, stun::SUCCESS, asked.txid);
                        if asked.method == stun::ALLOCATE {
                            m.add(stun::ATTR_XOR_RELAYED_ADDRESS, stun::encode_xor_address("198.51.100.20:40000".parse().unwrap(), &asked.txid));
                            m.add(stun::ATTR_XOR_MAPPED_ADDRESS, stun::encode_xor_address("192.0.2.30:51000".parse().unwrap(), &asked.txid));
                            m.add(stun::ATTR_LIFETIME, 600u32.to_be_bytes().to_vec());
                        }
                        m
                    }
                };
                if stream.write_all(&reply.encode(None, true)).await.is_err() {
                    return;
                }
            }
        }
    }

    /// A QUIC tunnel whose one end goes through a relay over a stream (as TURN over TLS), paced like a Cloudflare
    /// allocation: quinn on that end polls only its UDP socket, so datagrams that come down the stream must wake it.
    /// 2 MiB go out and back intact, and every frame on the stream stays within 1,280 bytes with its padding.
    #[tokio::test]
    async fn quic_runs_through_a_stream_relay() {
        const CHANNEL: u16 = 0x4321;
        let (mux_a, mux_b) = (Mux::bind(0).unwrap(), Mux::bind(0).unwrap());
        let addr_b: std::net::SocketAddr = format!("127.0.0.1:{}", mux_b.port()).parse().unwrap();
        let (ours, mut theirs) = tokio::io::duplex(1 << 20);
        let key = attach(&mux_a, ours);
        let relayed = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let relayed_addr = crate::addrs::canonical(relayed.local_addr().unwrap());
        let largest = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        {
            // The relay: frames from the stream go to B over UDP unwrapped; B's datagrams come back framed and padded.
            let largest = largest.clone();
            tokio::spawn(async move {
                let (mut buf, mut chunk, mut down) = (Vec::new(), vec![0u8; 65_536], vec![0u8; 65_536]);
                loop {
                    tokio::select! {
                        read = theirs.read(&mut chunk) => {
                            let Ok(n) = read else { return };
                            if n == 0 { return }
                            buf.extend_from_slice(&chunk[..n]);
                            while let Ok(Some((len, padded))) = frame(&buf) {
                                largest.fetch_max(padded, std::sync::atomic::Ordering::Relaxed);
                                if let Some((CHANNEL, payload)) = stun::parse_channel_data(&buf[..len]) {
                                    let _ = relayed.send_to(payload, addr_b).await;
                                }
                                buf.drain(..padded);
                            }
                        }
                        Ok((n, _)) = relayed.recv_from(&mut down) => {
                            let mut framed = stun::channel_data(CHANNEL, &down[..n]);
                            pad(&mut framed);
                            if theirs.write_all(&framed).await.is_err() { return }
                        }
                    }
                }
            });
        }
        mux_a.bound(key, addr_b, CHANNEL);
        mux_a.set_pace(key, 40_000);
        let (va, vb) = (mux_a.new_virtual(), mux_b.new_virtual());
        let via_relay = Path { via: Via::Turn(key), remote: addr_b };
        mux_a.map_path(via_relay, va);
        mux_a.select_path(va, via_relay);
        mux_b.map_path(Path::direct(relayed_addr), vb);
        mux_b.select_path(vb, Path::direct(relayed_addr));
        let runtime = Arc::new(quinn::TokioRuntime);
        let identity = crate::quic::Identity::generate();
        let server = quinn::Endpoint::new_with_abstract_socket(crate::quic::endpoint_config(), Some(crate::quic::server_config(&identity, crate::quic::Mtu::Base)), mux_b.clone(), runtime.clone()).unwrap();
        let client = quinn::Endpoint::new_with_abstract_socket(crate::quic::endpoint_config(), None, mux_a.clone(), runtime).unwrap();
        tokio::spawn(async move {
            let conn = server.accept().await.unwrap().await.unwrap();
            let (mut send, mut recv) = conn.accept_bi().await.unwrap();
            let mut buf = vec![0u8; 64 << 10];
            while let Ok(Some(n)) = recv.read(&mut buf).await {
                if send.write_all(&buf[..n]).await.is_err() {
                    break;
                }
            }
        });
        let config = crate::quic::client_config(&crate::quic::Identity::generate(), None, Duration::from_secs(5), crate::quic::Mtu::Base);
        let conn = tokio::time::timeout(Duration::from_secs(10), client.connect_with(config, va, "bridgey").unwrap()).await.expect("handshake in time").expect("handshake");
        let (mut send, mut recv) = conn.open_bi().await.unwrap();
        let data: Vec<u8> = (0..2usize << 20).map(|i| (i % 251) as u8).collect();
        let mut back = vec![0u8; data.len()];
        let (written, read) = tokio::time::timeout(Duration::from_secs(60), async { tokio::join!(send.write_all(&data), recv.read_exact(&mut back)) }).await.expect("the echo in time");
        written.unwrap();
        read.unwrap();
        assert!(back == data, "the echo differs");
        let largest = largest.load(std::sync::atomic::Ordering::Relaxed);
        assert!(largest <= 1_280, "largest frame on the stream: {largest}");
    }

    /// A Cloudflare grant as the control service sends it, used over TLS: its URLs give UDP 3478 first and TLS on 443
    /// as the fallback, and an allocation and a permission work over the stream with its credentials.
    #[tokio::test]
    async fn a_cloudflare_grant_allocates_over_a_stream() {
        let text = r#"{"t":"relay.grant","sid":"warm","relay":{"id":"cf","kind":"cloudflare","urls":["turn:turn.cloudflare.com:3478?transport=udp","turns:turn.cloudflare.com:443?transport=tcp"],"username":"cf-user","credential":"cf-pass","expiresAt":1795521600000,"maxKbps":40000}}"#;
        let Some(Msg::RelayGrantMsg { relay: grant, .. }) = Msg::parse(text) else { panic!("a grant") };
        assert!(grant.is_cloudflare() && grant.spki.is_none());
        assert_eq!(grant.urls.iter().find_map(|u| turn::parse_udp_url(u)), Some(("turn.cloudflare.com".into(), 3478)));
        assert_eq!(grant.urls.iter().find_map(|u| turn::parse_tls_url(u)), Some(("turn.cloudflare.com".into(), 443)));
        assert_eq!(crate::ice::relay_type(&grant.kind), crate::ice::TYPE_RELAY_CLOUDFLARE);
        let mux = Mux::bind(0).unwrap();
        let (ours, relay) = tokio::io::duplex(65_536);
        let key = attach(&mux, ours);
        tokio::spawn(fake_relay(relay, "cf-user", "cf-pass"));
        let allocation = Allocation::allocate(mux.clone(), key, &grant.id, &grant.username, &grant.credential).await.expect("allocated over the stream");
        assert_eq!(allocation.relayed, "198.51.100.20:40000".parse().unwrap());
        assert_eq!(allocation.server, key);
        let peer: std::net::IpAddr = "203.0.113.5".parse().unwrap();
        allocation.permit(&[peer]).await.expect("permitted");
        assert!(mux.has_permission(key, peer));
        // Paced at the grant's rate like any Cloudflare allocation.
        mux.set_pace(key, grant.max_kbps);
        mux.send_path(Path { via: Via::Turn(key), remote: std::net::SocketAddr::new(peer, 9) }, b"x").unwrap();
    }

    #[test]
    fn frames() {
        assert_eq!(frame(&[0x00, 0x01, 0x00]), Ok(None));
        let binding = Message::request(stun::BINDING).encode(None, true);
        assert_eq!(frame(&binding), Ok(Some((binding.len(), binding.len()))));
        let mut data = stun::channel_data(0x4001, b"hello");
        assert_eq!(frame(&data), Ok(None), "9 bytes with padding to 12: incomplete");
        pad(&mut data);
        assert_eq!(data.len(), 12);
        assert_eq!(frame(&data), Ok(Some((9, 12))));
        assert_eq!(frame(&[0x16, 0x03, 0x01, 0x00]), Err(()));
    }

    /// A relay at the other end of a stream: requests go down it padded, answers and ChannelData come back to the mux.
    #[tokio::test]
    async fn a_stream_relay_carries_stun_and_channel_data() {
        let mux = Mux::bind(0).unwrap();
        let (ours, mut relay) = tokio::io::duplex(65_536);
        let key = attach(&mux, ours);
        let peer: SocketAddr = "203.0.113.9:5000".parse().unwrap();
        mux.bound(key, peer, 0x4003);
        // A Binding transaction answered by the relay over the stream.
        let request = Message::request(stun::BINDING);
        let txid = request.txid;
        let bytes = request.encode(None, true);
        let len = bytes.len();
        let relay_task = tokio::spawn(async move {
            let mut got = vec![0u8; len];
            relay.read_exact(&mut got).await.unwrap();
            let asked = Message::decode(&got).unwrap();
            let mut answer = Message::new(stun::BINDING, stun::SUCCESS, asked.txid);
            answer.add(stun::ATTR_XOR_MAPPED_ADDRESS, stun::encode_xor_address("198.51.100.4:1234".parse().unwrap(), &asked.txid));
            relay.write_all(&answer.encode(None, true)).await.unwrap();
            // Then a datagram from the peer on the channel (padded), and one of ours going out.
            let mut data = stun::channel_data(0x4003, b"from-peer");
            pad(&mut data);
            relay.write_all(&data).await.unwrap();
            let mut out = [0u8; 12];
            relay.read_exact(&mut out).await.unwrap();
            out
        });
        // One send, no retransmit: a stream is reliable.
        let (answer, _) = mux.transact_rto(Path::direct(key), &bytes, txid, 1, true, Duration::from_secs(5)).await.expect("answered over the stream");
        assert_eq!(answer.xor_address(stun::ATTR_XOR_MAPPED_ADDRESS), Some("198.51.100.4:1234".parse().unwrap()));
        mux.send_path(Path { via: Via::Turn(key), remote: peer }, b"ours!").unwrap();
        let out = relay_task.await.unwrap();
        assert_eq!(&out[..9], &stun::channel_data(0x4003, b"ours!")[..]);
        assert_eq!(&out[9..], &[0, 0, 0]);
    }
}
