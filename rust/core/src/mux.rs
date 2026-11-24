//! One UDP socket per node, shared by STUN, TURN and QUIC (spec 7.4, RFC 9443).
//!
//! First byte 0 to 3 is STUN; 64 to 79 from a TURN server we use is ChannelData; anything else is
//! QUIC. Paths found by ICE get a stable virtual address, so quinn sees one peer address while the
//! path underneath moves between pairs (a relay, a direct pair) without dropping the connection.
//!
//! A relay reached over TLS (turn_tls.rs) is a stream at a virtual address of its own: what would go to it over UDP
//! goes down the stream. What leaves through a Cloudflare allocation is paced to the grant's rate (Cloudflare drops
//! packets above about 50 to 100 Mbit/s per allocation).

use crate::addrs::canonical;
use crate::stun::{self, Message};
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::io::{self, IoSliceMut};
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// How a datagram travels: straight from our socket, or through our allocation on a TURN server.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Via {
    Direct,
    Turn(SocketAddr),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Path {
    pub via: Via,
    pub remote: SocketAddr,
}

impl Path {
    pub fn direct(remote: SocketAddr) -> Path {
        Path { via: Via::Direct, remote: canonical(remote) }
    }
}

/// An incoming ICE connectivity check, for the agent that owns the local ufrag.
pub struct IceRequest {
    pub msg: Message,
    pub path: Path,
}

struct Datagram {
    data: Vec<u8>,
    src: SocketAddr,
}

/// Channel numbers of one TURN allocation, both ways.
#[derive(Default)]
pub struct Channels {
    by_peer: HashMap<SocketAddr, u16>,
    by_number: HashMap<u16, SocketAddr>,
    /// Numbers handed out for binds in flight, so two binds never share one.
    reserved: HashMap<SocketAddr, u16>,
    next: u16,
    /// Peer addresses with a permission (CreatePermission): datagrams to them go as Send indications
    /// until a channel is bound, so a relay path works one round trip earlier.
    permitted: HashSet<IpAddr>,
    /// Channels no longer refreshed (their peer left), kept for 11 minutes: the relay holds a binding for up to 10,
    /// keeps delivering that peer's data on it, and refuses a different number for the same peer.
    retired: HashMap<SocketAddr, (u16, std::time::Instant)>,
}

#[derive(Default)]
struct State {
    waiters: HashMap<[u8; 12], oneshot::Sender<(Message, Path)>>,
    turns: HashMap<SocketAddr, Channels>,
    ice: HashMap<String, mpsc::UnboundedSender<IceRequest>>,
    v_by_path: HashMap<Path, SocketAddr>,
    path_by_v: HashMap<SocketAddr, Path>,
    next_v: u32,
    /// Relays over TLS: their virtual address and the queue their stream writes from.
    streams: HashMap<SocketAddr, mpsc::Sender<Vec<u8>>>,
    next_stream: u32,
    /// Paced relays: what leaves through our allocation there waits in this queue for its turn.
    pacers: HashMap<SocketAddr, mpsc::Sender<Vec<u8>>>,
}

#[derive(Default)]
pub struct Counters {
    pub direct_in: AtomicU64,
    pub direct_out: AtomicU64,
    pub relay_in: AtomicU64,
    pub relay_out: AtomicU64,
    /// QUIC datagrams the OS refused to send (counted as lost), and the last reason, for diagnostics.
    pub send_errors: AtomicU64,
    pub last_send_error: Mutex<String>,
}

pub struct Mux {
    sock: tokio::net::UdpSocket,
    local: SocketAddr,
    v6: bool,
    quic_tx: mpsc::Sender<Datagram>,
    quic_rx: Mutex<mpsc::Receiver<Datagram>>,
    state: Mutex<State>,
    /// Debug and tests: no direct traffic at all, as if every network blocked it.
    pub relay_only: AtomicBool,
    pub counters: Counters,
}

impl fmt::Debug for Mux {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Mux").field("local", &self.local).finish()
    }
}

const VIRTUAL_PREFIX: [u16; 3] = [0xfdb7, 0x1d9e, 0xc0ec];
/// Relays over TLS get addresses from a prefix of their own: never a QUIC peer, never sent to over UDP.
const STREAM_PREFIX: [u16; 3] = [0xfdb7, 0x1d9e, 0xc0ed];
/// Datagrams waiting for a paced relay: about 60 ms at 40 Mbit/s. A full queue drops (QUIC sees a loss and slows).
const PACE_QUEUE: usize = 256;

pub fn is_virtual(addr: SocketAddr) -> bool {
    match addr.ip() {
        IpAddr::V6(v6) => v6.segments()[..3] == VIRTUAL_PREFIX,
        _ => false,
    }
}

/// A relay reached over TLS (its stream's virtual address).
pub fn is_stream(addr: SocketAddr) -> bool {
    match addr.ip() {
        IpAddr::V6(v6) => v6.segments()[..3] == STREAM_PREFIX,
        _ => false,
    }
}

impl Mux {
    /// Binds `port` (dual-stack where possible), or any free port when it is taken.
    pub fn bind(port: u16) -> io::Result<Arc<Mux>> {
        let std_sock = bind_socket(port).or_else(|_| bind_socket(0))?;
        std_sock.set_nonblocking(true)?;
        let sock = tokio::net::UdpSocket::from_std(std_sock)?;
        let local = sock.local_addr()?;
        let (quic_tx, quic_rx) = mpsc::channel(QUIC_QUEUE);
        let mux = Arc::new(Mux {
            v6: local.is_ipv6(),
            sock,
            local,
            quic_tx,
            quic_rx: Mutex::new(quic_rx),
            state: Mutex::new(State::default()),
            relay_only: AtomicBool::new(false),
            counters: Counters::default(),
        });
        let reader = mux.clone();
        tokio::spawn(async move { reader.read_loop().await });
        Ok(mux)
    }

    pub fn port(&self) -> u16 {
        self.local.port()
    }

    fn relay_only(&self) -> bool {
        self.relay_only.load(Ordering::Relaxed)
    }

    fn family(&self, addr: SocketAddr) -> SocketAddr {
        match (self.v6, addr) {
            (true, SocketAddr::V4(v4)) => SocketAddr::new(IpAddr::V6(v4.ip().to_ipv6_mapped()), v4.port()),
            _ => addr,
        }
    }

    async fn read_loop(self: Arc<Self>) {
        let mut buf = vec![0u8; 65_536];
        loop {
            let (n, src) = match self.sock.recv_from(&mut buf).await {
                Ok(x) => x,
                Err(e) if e.kind() == io::ErrorKind::ConnectionReset => continue,
                Err(_) => {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    continue;
                }
            };
            let src = canonical(src);
            self.receive(&buf[..n], src);
        }
    }

    fn receive(&self, data: &[u8], src: SocketAddr) {
        let from_turn = self.state.lock().unwrap().turns.contains_key(&src);
        if from_turn {
            self.counters.relay_in.fetch_add(data.len() as u64, Ordering::Relaxed);
            if let Some((number, payload)) = stun::parse_channel_data(data) {
                let peer = self.state.lock().unwrap().turns.get(&src).and_then(|c| c.by_number.get(&number).copied());
                if let Some(peer) = peer {
                    self.inner(payload, Path { via: Via::Turn(src), remote: peer });
                }
                return;
            }
            if let Some(msg) = Message::decode(data) {
                if msg.method == stun::DATA && msg.class == stun::INDICATION {
                    if let (Some(peer), Some(payload)) = (msg.xor_address(stun::ATTR_XOR_PEER_ADDRESS), msg.get(stun::ATTR_DATA)) {
                        self.inner(payload, Path { via: Via::Turn(src), remote: canonical(peer) });
                    }
                } else {
                    self.deliver(msg, Path::direct(src));
                }
            }
            return;
        }
        self.counters.direct_in.fetch_add(data.len() as u64, Ordering::Relaxed);
        if self.relay_only() && !stun::is_stun(data) {
            return;
        }
        self.inner(data, Path::direct(src));
    }

    fn inner(&self, data: &[u8], path: Path) {
        if stun::is_stun(data) {
            let Some(msg) = Message::decode(data) else { return };
            match msg.class {
                stun::REQUEST if msg.method == stun::BINDING => {
                    if self.relay_only() && path.via == Via::Direct {
                        return;
                    }
                    let Some(user) = msg.string(stun::ATTR_USERNAME) else { return };
                    let local = user.split(':').next().unwrap_or_default().to_string();
                    let agent = self.state.lock().unwrap().ice.get(&local).cloned();
                    if let Some(agent) = agent {
                        let _ = agent.send(IceRequest { msg, path });
                    }
                }
                stun::SUCCESS | stun::ERROR => self.deliver(msg, path),
                _ => {}
            }
            return;
        }
        let mapped = {
            let state = self.state.lock().unwrap();
            match state.v_by_path.get(&path) {
                Some(v) => Some(*v),
                None if path.via == Via::Direct => Some(path.remote),
                None => None,
            }
        };
        if let Some(src) = mapped {
            let _ = self.quic_tx.try_send(Datagram { data: data.to_vec(), src });
        }
    }

    fn deliver(&self, msg: Message, path: Path) {
        let waiter = self.state.lock().unwrap().waiters.remove(&msg.txid);
        if let Some(waiter) = waiter {
            let _ = waiter.send((msg, path));
        }
    }

    /// Sends one datagram along `path`. Through TURN it needs a bound channel; without one it is dropped.
    pub fn send_path(&self, path: Path, data: &[u8]) -> io::Result<()> {
        match path.via {
            Via::Direct => {
                if self.relay_only() {
                    return Ok(());
                }
                self.counters.direct_out.fetch_add(data.len() as u64, Ordering::Relaxed);
                self.sock.try_send_to(data, self.family(path.remote)).map(|_| ())
            }
            Via::Turn(server) => {
                let (channel, permitted, pacer) = {
                    let state = self.state.lock().unwrap();
                    let c = state.turns.get(&server);
                    (c.and_then(|c| c.by_peer.get(&path.remote).copied()), c.is_some_and(|c| c.permitted.contains(&path.remote.ip())), state.pacers.get(&server).cloned())
                };
                let framed = match channel {
                    Some(channel) => stun::channel_data(channel, data),
                    None if permitted => {
                        let mut m = Message::new(stun::SEND, stun::INDICATION, stun::random_txid());
                        m.add(stun::ATTR_XOR_PEER_ADDRESS, stun::encode_xor_address(path.remote, &m.txid));
                        m.add(stun::ATTR_DATA, data.to_vec());
                        m.encode(None, false)
                    }
                    None => return Ok(()),
                };
                self.counters.relay_out.fetch_add(framed.len() as u64, Ordering::Relaxed);
                if let Some(pacer) = pacer {
                    // Queued for its turn; a full queue drops it, as a congested link would.
                    let _ = pacer.try_send(framed);
                    return Ok(());
                }
                self.out(server, &framed)
            }
        }
    }

    /// Sends to a TURN or STUN server itself (allowed in relay-only mode).
    fn send_server(&self, server: SocketAddr, data: &[u8]) -> io::Result<()> {
        self.counters.relay_out.fetch_add(data.len() as u64, Ordering::Relaxed);
        self.out(server, data)
    }

    /// To a relay or STUN server: down its TLS stream when it is one, else over the UDP socket.
    fn out(&self, server: SocketAddr, data: &[u8]) -> io::Result<()> {
        if is_stream(server) {
            let stream = self.state.lock().unwrap().streams.get(&server).cloned();
            return match stream {
                Some(stream) => {
                    let _ = stream.try_send(data.to_vec());
                    Ok(())
                }
                None => Err(io::Error::new(io::ErrorKind::NotConnected, "relay stream closed")),
            };
        }
        self.sock.try_send_to(data, self.family(server)).map(|_| ())
    }

    /// A virtual address for a relay reached over TLS.
    pub fn new_stream_key(&self) -> SocketAddr {
        let mut state = self.state.lock().unwrap();
        state.next_stream += 1;
        let n = state.next_stream;
        let ip = Ipv6Addr::new(STREAM_PREFIX[0], STREAM_PREFIX[1], STREAM_PREFIX[2], 0, 0, 0, (n >> 16) as u16, n as u16);
        SocketAddr::new(IpAddr::V6(ip), 443)
    }

    /// What goes to the relay at `key` is written to `stream` from now on; what it sends comes in through
    /// [Mux::receive_stream].
    pub fn add_stream(&self, key: SocketAddr, stream: mpsc::Sender<Vec<u8>>) {
        let mut state = self.state.lock().unwrap();
        state.streams.insert(key, stream);
        state.turns.entry(key).or_default();
    }

    /// One message (STUN or ChannelData, without padding) the relay at `key` sent down its stream.
    pub fn receive_stream(&self, data: &[u8], key: SocketAddr) {
        self.receive(data, key);
    }

    /// The relay's stream closed: nothing more goes to it.
    pub fn end_stream(&self, key: SocketAddr) {
        self.state.lock().unwrap().streams.remove(&key);
    }

    /// Paces what leaves through our allocation on `server` to `kbps` (a Cloudflare grant's `maxKbps`).
    pub fn set_pace(self: &Arc<Self>, server: SocketAddr, kbps: u32) {
        if kbps == 0 {
            return;
        }
        let rx = {
            let mut state = self.state.lock().unwrap();
            if state.pacers.contains_key(&server) {
                return;
            }
            let (tx, rx) = mpsc::channel(PACE_QUEUE);
            state.pacers.insert(server, tx);
            rx
        };
        tokio::spawn(pace(Arc::downgrade(self), server, kbps, rx));
    }

    /// A STUN transaction with retransmits (250 ms, doubling, `tries` sends).
    pub async fn transact(&self, path: Path, bytes: &[u8], txid: [u8; 12], tries: u32, to_server: bool) -> Option<(Message, Path)> {
        self.transact_rto(path, bytes, txid, tries, to_server, Duration::from_millis(250)).await
    }

    /// [Mux::transact] with the first retransmit after `rto` (ICE checks use 100 ms: a lost first check on a
    /// relay path that was not open yet costs a tenth of a second, not a quarter).
    pub async fn transact_rto(&self, path: Path, bytes: &[u8], txid: [u8; 12], tries: u32, to_server: bool, rto: Duration) -> Option<(Message, Path)> {
        let (tx, mut rx) = oneshot::channel();
        self.state.lock().unwrap().waiters.insert(txid, tx);
        if to_server && is_stream(path.remote) {
            // A relay over TLS: the stream is reliable, so one send, and the whole retransmit schedule to answer.
            let total = (0..tries).fold((Duration::ZERO, rto), |(sum, r), _| (sum + r, (r * 2).min(Duration::from_secs(2)))).0;
            let _ = self.send_server(path.remote, bytes);
            let answer = tokio::time::timeout(total, &mut rx).await;
            self.state.lock().unwrap().waiters.remove(&txid);
            return answer.ok().and_then(|a| a.ok());
        }
        let mut rto = rto;
        for _ in 0..tries {
            // A socket whose writability the reactor has not seen yet (just bound) refuses try_send with WouldBlock;
            // waiting here keeps the first request of a fresh node from being lost to a retransmit timer.
            let _ = tokio::time::timeout(Duration::from_millis(50), self.sock.writable()).await;
            let _ = if to_server { self.send_server(path.remote, bytes) } else { self.send_path(path, bytes) };
            tokio::select! {
                answer = &mut rx => return answer.ok(),
                _ = tokio::time::sleep(rto) => {}
            }
            rto = (rto * 2).min(Duration::from_secs(2));
        }
        self.state.lock().unwrap().waiters.remove(&txid);
        None
    }

    pub fn reply(&self, path: Path, bytes: &[u8]) {
        let _ = self.send_path(path, bytes);
    }

    pub fn add_turn(&self, server: SocketAddr) {
        self.state.lock().unwrap().turns.entry(server).or_default();
    }

    pub fn remove_turn(&self, server: SocketAddr) {
        let mut state = self.state.lock().unwrap();
        state.turns.remove(&server);
        state.streams.remove(&server);
        state.pacers.remove(&server);
        state.v_by_path.retain(|p, _| p.via != Via::Turn(server));
        state.path_by_v.retain(|_, p| p.via != Via::Turn(server));
    }

    pub fn has_channel(&self, server: SocketAddr, peer: SocketAddr) -> bool {
        self.state.lock().unwrap().turns.get(&server).map(|c| c.by_peer.contains_key(&peer)).unwrap_or(false)
    }

    /// Datagrams to `peer` through our allocation on `server` can leave now (a channel or a permission).
    pub fn can_send(&self, server: SocketAddr, peer: SocketAddr) -> bool {
        self.state.lock().unwrap().turns.get(&server).map(|c| c.by_peer.contains_key(&peer) || c.permitted.contains(&peer.ip())).unwrap_or(false)
    }

    pub fn has_permission(&self, server: SocketAddr, ip: IpAddr) -> bool {
        self.state.lock().unwrap().turns.get(&server).map(|c| c.permitted.contains(&ip)).unwrap_or(false)
    }

    /// The relay installed permissions for `ips` on our allocation there.
    pub fn permit(&self, server: SocketAddr, ips: &[IpAddr]) {
        if let Some(channels) = self.state.lock().unwrap().turns.get_mut(&server) {
            channels.permitted.extend(ips.iter().copied());
        }
    }

    /// Keeps only `keep` among the permitted addresses (a long-lived allocation would otherwise stay open to every
    /// address a session ever used); the relay lets the others lapse after 5 minutes.
    pub fn retain_permitted(&self, server: SocketAddr, keep: &HashSet<IpAddr>) {
        if let Some(channels) = self.state.lock().unwrap().turns.get_mut(&server) {
            channels.permitted.retain(|ip| keep.contains(ip));
            // A bound channel is re-bound every 4 minutes, which would renew the relay's permission for its address
            // too: channels to peers not kept stop being refreshed. Their numbers stay known until the relay must
            // have let them go, because it keeps using them for that peer's data until then.
            let now = std::time::Instant::now();
            let gone: Vec<(SocketAddr, u16)> = channels.by_peer.iter().filter(|(peer, _)| !keep.contains(&peer.ip())).map(|(p, n)| (*p, *n)).collect();
            for (peer, number) in gone {
                channels.by_peer.remove(&peer);
                channels.retired.insert(peer, (number, now));
            }
            channels.reserved.retain(|peer, _| keep.contains(&peer.ip()));
            channels.retired.retain(|_, (_, at)| now.duration_since(*at) < Duration::from_secs(660));
            let live: HashSet<u16> = channels.by_peer.values().chain(channels.retired.values().map(|(n, _)| n)).copied().collect();
            channels.by_number.retain(|number, _| live.contains(number));
        }
    }

    /// Every address with a permission on `server`, for refreshing them before the relay's 5 minutes run out.
    pub fn permitted(&self, server: SocketAddr) -> Vec<IpAddr> {
        self.state.lock().unwrap().turns.get(&server).map(|c| c.permitted.iter().copied().collect()).unwrap_or_default()
    }

    /// Channel numbers start at a random point for each allocation: a channel a killed process bound is never
    /// reused by mistake if the relay still remembers it.
    pub fn seed_channels(&self, server: SocketAddr, seed: u16) {
        let mut state = self.state.lock().unwrap();
        let channels = state.turns.entry(server).or_default();
        if channels.by_peer.is_empty() && channels.reserved.is_empty() {
            channels.next = seed % 0x0FFF;
        }
    }

    /// The channel number to bind for `peer`: its existing or reserved one, or the next free one.
    pub fn channel_for(&self, server: SocketAddr, peer: SocketAddr) -> u16 {
        let mut state = self.state.lock().unwrap();
        let channels = state.turns.entry(server).or_default();
        if let Some(n) = channels.by_peer.get(&peer).or(channels.reserved.get(&peer)) {
            return *n;
        }
        if let Some((n, _)) = channels.retired.remove(&peer) {
            channels.reserved.insert(peer, n);
            return n;
        }
        let n = 0x4000 + (channels.next % 0x0FFF);
        channels.next += 1;
        channels.reserved.insert(peer, n);
        n
    }

    pub fn bound(&self, server: SocketAddr, peer: SocketAddr, number: u16) {
        if let Some(channels) = self.state.lock().unwrap().turns.get_mut(&server) {
            channels.reserved.remove(&peer);
            channels.retired.remove(&peer);
            channels.by_peer.insert(peer, number);
            channels.by_number.insert(number, peer);
        }
    }

    /// Peers with a bound channel on `server`, for re-binding before the 10-minute expiry.
    pub fn channel_peers(&self, server: SocketAddr) -> Vec<SocketAddr> {
        self.state.lock().unwrap().turns.get(&server).map(|c| c.by_peer.keys().copied().collect()).unwrap_or_default()
    }

    pub fn register_ice(&self, ufrag: &str, tx: mpsc::UnboundedSender<IceRequest>) {
        self.state.lock().unwrap().ice.insert(ufrag.to_string(), tx);
    }

    pub fn unregister_ice(&self, ufrag: &str) {
        self.state.lock().unwrap().ice.remove(ufrag);
    }

    pub fn new_virtual(&self) -> SocketAddr {
        let mut state = self.state.lock().unwrap();
        state.next_v += 1;
        let n = state.next_v;
        let ip = Ipv6Addr::new(VIRTUAL_PREFIX[0], VIRTUAL_PREFIX[1], VIRTUAL_PREFIX[2], 0, 0, 0, (n >> 16) as u16, n as u16);
        SocketAddr::new(IpAddr::V6(ip), 1)
    }

    /// Datagrams arriving on `path` belong to the connection at `vaddr`.
    pub fn map_path(&self, path: Path, vaddr: SocketAddr) {
        self.state.lock().unwrap().v_by_path.insert(path, vaddr);
    }

    /// Datagrams for `vaddr` leave on `path`.
    pub fn select_path(&self, vaddr: SocketAddr, path: Path) {
        self.state.lock().unwrap().path_by_v.insert(vaddr, path);
    }

    pub fn selected(&self, vaddr: SocketAddr) -> Option<Path> {
        self.state.lock().unwrap().path_by_v.get(&vaddr).copied()
    }

    pub fn forget_virtual(&self, vaddr: SocketAddr) {
        let mut state = self.state.lock().unwrap();
        state.path_by_v.remove(&vaddr);
        state.v_by_path.retain(|_, v| *v != vaddr);
    }
}

/// A token bucket in front of one relay: datagrams leave at `kbps` on average. A wake-up that comes late (a busy device,
/// coarse timers) may send what the time since the last one allows, up to 15 ms worth, so the average holds.
async fn pace(mux: Weak<Mux>, server: SocketAddr, kbps: u32, mut queue: mpsc::Receiver<Vec<u8>>) {
    let rate = f64::from(kbps) * 1_000.0 / 8.0;
    let burst = (rate * 0.015).max(16_384.0);
    let mut tokens = burst;
    let mut last = std::time::Instant::now();
    while let Some(datagram) = queue.recv().await {
        let need = datagram.len() as f64;
        let refill = |tokens: &mut f64, last: &mut std::time::Instant| {
            let now = std::time::Instant::now();
            *tokens = (*tokens + now.duration_since(*last).as_secs_f64() * rate).min(burst.max(need));
            *last = now;
        };
        refill(&mut tokens, &mut last);
        if tokens < need {
            tokio::time::sleep(Duration::from_secs_f64((need - tokens) / rate)).await;
            refill(&mut tokens, &mut last);
        }
        tokens -= need;
        let Some(mux) = mux.upgrade() else { break };
        let _ = mux.out(server, &datagram);
    }
}

const SOCKET_BUFFER: usize = 4 << 20;
/// Datagrams waiting for QUIC: a full window of 1,200-byte packets (16 MiB) fits.
const QUIC_QUEUE: usize = 16_384;

fn bind_socket(port: u16) -> io::Result<std::net::UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    match Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP)) {
        Ok(socket) => {
            socket.set_only_v6(false)?;
            // Room for a burst at full speed (the defaults, around 200 KB, drop packets a QUIC window sends at once).
            // The OS caps these at its own maximum; less is not an error.
            let _ = socket.set_recv_buffer_size(SOCKET_BUFFER);
            let _ = socket.set_send_buffer_size(SOCKET_BUFFER);
            socket.bind(&SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port).into())?;
            Ok(socket.into())
        }
        Err(_) => std::net::UdpSocket::bind(("0.0.0.0", port)),
    }
}

impl quinn::AsyncUdpSocket for Mux {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn quinn::UdpPoller>> {
        Box::pin(Poller { mux: self })
    }

    fn try_send(&self, transmit: &quinn::udp::Transmit) -> io::Result<()> {
        let dest = canonical(transmit.destination);
        let path = if is_virtual(dest) {
            match self.selected(dest) {
                Some(path) => path,
                None => return Ok(()),
            }
        } else {
            Path::direct(dest)
        };
        match self.send_path(path, transmit.contents) {
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Err(e),
            // Unreachable networks and the like: QUIC treats the packet as lost.
            Err(e) => {
                self.counters.send_errors.fetch_add(1, Ordering::Relaxed);
                *self.counters.last_send_error.lock().unwrap() = format!("{dest}: {e}");
                Ok(())
            }
            Ok(()) => Ok(()),
        }
    }

    fn poll_recv(&self, cx: &mut Context, bufs: &mut [IoSliceMut<'_>], meta: &mut [quinn::udp::RecvMeta]) -> Poll<io::Result<usize>> {
        let mut rx = self.quic_rx.lock().unwrap();
        // As many waiting datagrams as quinn has buffers for, in one call (one wake-up per batch, not per packet).
        let mut filled = 0;
        while filled < bufs.len().min(meta.len()) {
            let next = if filled == 0 {
                match rx.poll_recv(cx) {
                    Poll::Ready(Some(d)) => d,
                    Poll::Ready(None) => return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "mux closed"))),
                    Poll::Pending => return Poll::Pending,
                }
            } else {
                match rx.try_recv() {
                    Ok(d) => d,
                    Err(_) => break,
                }
            };
            let len = next.data.len().min(bufs[filled].len());
            bufs[filled][..len].copy_from_slice(&next.data[..len]);
            // quinn keeps an IPv4 peer of a dual-stack endpoint as its mapped IPv6 address (Endpoint::connect_with),
            // and drops handshake packets from any other form of it: hand IPv4 sources over the same way.
            meta[filled] = quinn::udp::RecvMeta { addr: self.family(next.src), len, stride: len, ecn: None, dst_ip: None };
            filled += 1;
        }
        Poll::Ready(Ok(filled))
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.local)
    }

    fn may_fragment(&self) -> bool {
        true
    }
}

#[derive(Debug)]
struct Poller {
    mux: Arc<Mux>,
}

impl quinn::UdpPoller for Poller {
    fn poll_writable(self: Pin<&mut Self>, cx: &mut Context) -> Poll<io::Result<()>> {
        self.mux.sock.poll_send_ready(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A QUIC handshake to an IPv4 address of a dual-stack endpoint: quinn tracks the server as ::ffff:a.b.c.d, so the
    /// mux must hand its replies over in that form (a Windows PC on IPv4 only never brought a tunnel up before).
    #[tokio::test]
    async fn quic_completes_over_ipv4_on_a_dual_stack_socket() {
        let runtime = Arc::new(quinn::TokioRuntime);
        let server_mux = Mux::bind(0).unwrap();
        let client_mux = Mux::bind(0).unwrap();
        let identity = crate::quic::Identity::generate();
        let server = quinn::Endpoint::new_with_abstract_socket(crate::quic::endpoint_config(), Some(crate::quic::server_config(&identity)), server_mux.clone(), runtime.clone()).unwrap();
        let client = quinn::Endpoint::new_with_abstract_socket(crate::quic::endpoint_config(), None, client_mux.clone(), runtime).unwrap();
        let accept = tokio::spawn(async move { server.accept().await.unwrap().await.map(|c| c.remote_address()) });
        let target: SocketAddr = format!("127.0.0.1:{}", server_mux.port()).parse().unwrap();
        let config = crate::quic::client_config(&crate::quic::Identity::generate(), None, Duration::from_secs(5));
        let conn = tokio::time::timeout(Duration::from_secs(5), client.connect_with(config, target, "bridgey").unwrap()).await.expect("handshake in time").expect("handshake");
        assert_eq!(canonical(conn.remote_address()), target);
        let seen = tokio::time::timeout(Duration::from_secs(5), accept).await.unwrap().unwrap().unwrap();
        assert_eq!(canonical(seen).ip(), target.ip());
    }

    /// A paced relay gets its datagrams at the set rate: 400 kbit/s lets about 50 KB through in a second, not all 120 KB
    /// at once, and none is lost while the queue has room.
    #[tokio::test]
    async fn paced_relay_keeps_to_its_rate() {
        let relay = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let server = canonical(relay.local_addr().unwrap());
        let mux = Mux::bind(0).unwrap();
        mux.add_turn(server);
        mux.set_pace(server, 400);
        let peer: SocketAddr = "203.0.113.7:4000".parse().unwrap();
        mux.bound(server, peer, 0x4001);
        mux.sock.writable().await.unwrap();
        let started = std::time::Instant::now();
        for _ in 0..100 {
            mux.send_path(Path { via: Via::Turn(server), remote: peer }, &[7u8; 1_196]).unwrap();
        }
        let mut buf = [0u8; 2048];
        let mut got = 0usize;
        let mut first_second = 0usize;
        while got < 100 * 1_200 {
            let (n, _) = tokio::time::timeout(Duration::from_secs(5), relay.recv_from(&mut buf)).await.expect("all arrive").unwrap();
            assert_eq!(stun::parse_channel_data(&buf[..n]).map(|(c, p)| (c, p.len())), Some((0x4001, 1_196)));
            got += n;
            if started.elapsed() < Duration::from_secs(1) {
                first_second += n;
            }
        }
        assert!(first_second <= 16_384 + 50_000 + 2_400, "{first_second} bytes in the first second");
        assert!(started.elapsed() >= Duration::from_millis(1_800), "{:?}", started.elapsed());
    }

    /// A relay over TLS: what goes to its virtual address goes down its stream, and nothing goes over UDP.
    #[tokio::test]
    async fn stream_relays_write_to_their_stream() {
        let mux = Mux::bind(0).unwrap();
        let key = mux.new_stream_key();
        assert!(is_stream(key) && !is_virtual(key));
        let (tx, mut rx) = mpsc::channel(8);
        mux.add_stream(key, tx);
        let peer: SocketAddr = "203.0.113.7:4000".parse().unwrap();
        mux.bound(key, peer, 0x4002);
        mux.send_path(Path { via: Via::Turn(key), remote: peer }, b"abc").unwrap();
        assert_eq!(stun::parse_channel_data(&rx.recv().await.unwrap()), Some((0x4002, &b"abc"[..])));
        mux.send_server(key, b"stun").unwrap();
        assert_eq!(rx.recv().await.unwrap(), b"stun");
        mux.end_stream(key);
        assert!(mux.send_server(key, b"x").is_err());
    }

    /// Through a relay with a permission but no channel yet, a datagram leaves as a Send indication (so a relay
    /// pair works before any ChannelBind); without either it is not sent at all.
    #[tokio::test]
    async fn send_indication_until_a_channel_is_bound() {
        let relay = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let server = canonical(relay.local_addr().unwrap());
        let mux = Mux::bind(0).unwrap();
        mux.add_turn(server);
        let peer: SocketAddr = "203.0.113.7:4000".parse().unwrap();
        let path = Path { via: Via::Turn(server), remote: peer };
        mux.sock.writable().await.unwrap();
        mux.send_path(path, b"before").unwrap();
        mux.permit(server, &[peer.ip()]);
        assert!(mux.can_send(server, peer) && !mux.has_channel(server, peer));
        mux.send_path(path, b"hello").unwrap();
        let mut buf = [0u8; 2048];
        let (n, _) = tokio::time::timeout(Duration::from_secs(2), relay.recv_from(&mut buf)).await.unwrap().unwrap();
        let msg = Message::decode(&buf[..n]).expect("a STUN message");
        assert_eq!((msg.method, msg.class), (stun::SEND, stun::INDICATION));
        assert_eq!(msg.xor_address(stun::ATTR_XOR_PEER_ADDRESS), Some(peer));
        assert_eq!(msg.get(stun::ATTR_DATA), Some(&b"hello"[..]));
        // Once bound, ChannelData.
        mux.bound(server, peer, 0x4001);
        mux.send_path(path, b"bound").unwrap();
        let (n, _) = tokio::time::timeout(Duration::from_secs(2), relay.recv_from(&mut buf)).await.unwrap().unwrap();
        assert_eq!(stun::parse_channel_data(&buf[..n]), Some((0x4001, &b"bound"[..])));
        // Trimmed: not refreshed any more, but its number still maps incoming data and is reused if bound again.
        mux.retain_permitted(server, &HashSet::new());
        assert!(mux.channel_peers(server).is_empty());
        assert_eq!(mux.state.lock().unwrap().turns[&server].by_number.get(&0x4001), Some(&peer));
        assert_eq!(mux.channel_for(server, peer), 0x4001);
    }
}
