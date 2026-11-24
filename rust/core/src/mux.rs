//! One UDP socket per node, shared by STUN, TURN and QUIC (spec 7.4, RFC 9443).
//!
//! First byte 0 to 3 is STUN; 64 to 79 from a TURN server we use is ChannelData; anything else is
//! QUIC. Paths found by ICE get a stable virtual address, so quinn sees one peer address while the
//! path underneath moves between pairs (a relay, a direct pair) without dropping the connection.
//!
//! The socket goes through quinn-udp: batches of datagrams per system call (GSO and GRO on Linux and
//! Android, recvmmsg where the platform has it) and no IP fragmentation, so QUIC can find a path's MTU.
//! Once quinn polls the socket it reads it directly, and QUIC datagrams from direct senders stay where
//! they landed; STUN and TURN are handled on the way. Each relayed datagram keeps its own ChannelData
//! header and stays within 1,280 bytes.

use crate::addrs::canonical;
use crate::stun::{self, Message};
use quinn::udp::{RecvMeta, Transmit, UdpSocketState};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::future::Future;
use std::io::{self, IoSliceMut};
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;
use tokio::io::Interest;
use tokio::sync::{mpsc, oneshot, Notify};

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
    udp: UdpSocketState,
    local: SocketAddr,
    v6: bool,
    /// QUIC datagrams that could not stay where they landed (relayed ones that arrive mixed, Data indications, or
    /// any read before quinn first polled): quinn gets these first.
    pending: Mutex<VecDeque<Datagram>>,
    /// quinn polls the socket itself; until it starts, a small reader serves STUN and TURN.
    attached: AtomicBool,
    attach: Notify,
    recv_waker: Mutex<Option<Waker>>,
    /// After an unexpected receive error, reading pauses briefly instead of spinning.
    recv_backoff: Mutex<Option<Pin<Box<tokio::time::Sleep>>>>,
    /// ChannelData frames of one relayed transmit.
    relay_scratch: Mutex<Vec<u8>>,
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

pub fn is_virtual(addr: SocketAddr) -> bool {
    match addr.ip() {
        IpAddr::V6(v6) => v6.segments()[..3] == VIRTUAL_PREFIX,
        _ => false,
    }
}

impl Mux {
    /// Binds `port` (dual-stack where possible), or any free port when it is taken.
    pub fn bind(port: u16) -> io::Result<Arc<Mux>> {
        let std_sock = bind_socket(port).or_else(|_| bind_socket(0))?;
        // Turns on GRO where there is one and turns off fragmentation (quinn's own sockets do the same).
        let udp = UdpSocketState::new((&std_sock).into())?;
        std_sock.set_nonblocking(true)?;
        let sock = tokio::net::UdpSocket::from_std(std_sock)?;
        let local = sock.local_addr()?;
        let mux = Arc::new(Mux {
            v6: local.is_ipv6(),
            sock,
            udp,
            local,
            pending: Mutex::new(VecDeque::new()),
            attached: AtomicBool::new(false),
            attach: Notify::new(),
            recv_waker: Mutex::new(None),
            recv_backoff: Mutex::new(None),
            relay_scratch: Mutex::new(Vec::new()),
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

    /// Serves STUN and TURN until quinn polls the socket itself (a mux without a QUIC endpoint, as in tests and the
    /// relay checks, keeps it for good).
    async fn read_loop(self: Arc<Self>) {
        let mut storage = vec![0u8; RECV_BUF * BATCH];
        let mut meta = [RecvMeta::default(); BATCH];
        loop {
            let read = tokio::select! {
                _ = self.attach.notified() => return,
                read = self.sock.async_io(Interest::READABLE, || {
                    let mut bufs: Vec<IoSliceMut<'_>> = storage.chunks_mut(RECV_BUF).map(IoSliceMut::new).collect();
                    self.udp.recv((&self.sock).into(), &mut bufs, &mut meta)
                }) => read,
            };
            match read {
                Ok(n) => {
                    for (i, m) in meta.iter().enumerate().take(n) {
                        let data = &storage[i * RECV_BUF..i * RECV_BUF + m.len];
                        let src = canonical(m.addr);
                        for segment in data.chunks(m.stride.max(1)) {
                            self.receive(segment, src);
                        }
                    }
                    if let Some(waker) = self.recv_waker.lock().unwrap().take() {
                        waker.wake();
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::ConnectionReset => continue,
                Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
            }
        }
    }

    /// One datagram the fast path could not keep in place: STUN and TURN are handled here, QUIC waits for quinn.
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
        if let Some(src) = self.quic_source(path) {
            let mut pending = self.pending.lock().unwrap();
            if pending.len() < PENDING_MAX {
                pending.push_back(Datagram { data: data.to_vec(), src });
            }
        }
    }

    /// The address quinn knows the sender of a QUIC datagram on `path` by, if any.
    fn quic_source(&self, path: Path) -> Option<SocketAddr> {
        let state = self.state.lock().unwrap();
        match state.v_by_path.get(&path) {
            Some(v) => Some(*v),
            None if path.via == Via::Direct => Some(path.remote),
            None => None,
        }
    }

    /// Where QUIC datagrams from `src` can stay in quinn's buffer as they are: a direct sender, not a relay we use.
    fn direct_source(&self, src: SocketAddr) -> Option<SocketAddr> {
        if self.relay_only() {
            return None;
        }
        let state = self.state.lock().unwrap();
        if state.turns.contains_key(&src) {
            return None;
        }
        Some(state.v_by_path.get(&Path::direct(src)).copied().unwrap_or(src))
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
                let (channel, permitted) = {
                    let state = self.state.lock().unwrap();
                    let c = state.turns.get(&server);
                    (c.and_then(|c| c.by_peer.get(&path.remote).copied()), c.is_some_and(|c| c.permitted.contains(&path.remote.ip())))
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
                self.sock.try_send_to(&framed, self.family(server)).map(|_| ())
            }
        }
    }

    /// A QUIC transmit from quinn along `path`: one datagram, or several of `segment` bytes (the last may be
    /// shorter) that leave in one system call where the OS can segment them (GSO).
    fn send_quic(&self, path: Path, contents: &[u8], segment: Option<usize>) -> io::Result<()> {
        let size = segment.unwrap_or(contents.len());
        match path.via {
            Via::Direct => {
                if self.relay_only() {
                    return Ok(());
                }
                self.counters.direct_out.fetch_add(contents.len() as u64, Ordering::Relaxed);
                self.send_batch(self.family(path.remote), contents, size)
            }
            Via::Turn(server) => {
                // Relayed datagrams stay within 1,280 bytes of UDP payload, ChannelData header included. A larger one
                // (an MTU probe, or packets sized for a direct pair before quinn notices the move) is lost on purpose.
                if size > RELAY_MAX_QUIC {
                    return Ok(());
                }
                let channel = self.state.lock().unwrap().turns.get(&server).and_then(|c| c.by_peer.get(&path.remote).copied());
                let Some(channel) = channel else {
                    // No channel yet: Send indications (or nothing), one per datagram.
                    for datagram in contents.chunks(size.max(1)) {
                        self.send_path(path, datagram)?;
                    }
                    return Ok(());
                };
                // Each datagram keeps its own ChannelData header; frames of one size still leave as one batch (over
                // UDP ChannelData needs no padding, RFC 8656 section 12.5).
                let mut framed = self.relay_scratch.lock().unwrap();
                framed.clear();
                for datagram in contents.chunks(size.max(1)) {
                    framed.extend_from_slice(&channel.to_be_bytes());
                    framed.extend_from_slice(&(datagram.len() as u16).to_be_bytes());
                    framed.extend_from_slice(datagram);
                }
                self.counters.relay_out.fetch_add(framed.len() as u64, Ordering::Relaxed);
                self.send_batch(self.family(server), &framed, size + 4)
            }
        }
    }

    /// Datagrams of `size` bytes (the last may be shorter) to `dest`: one GSO send where the socket has it, else one
    /// send each.
    fn send_batch(&self, dest: SocketAddr, contents: &[u8], size: usize) -> io::Result<()> {
        let size = size.max(1);
        if contents.len() > size && self.udp.max_gso_segments() <= 1 {
            for datagram in contents.chunks(size) {
                self.send_one(dest, datagram, None)?;
            }
            return Ok(());
        }
        self.send_one(dest, contents, (contents.len() > size).then_some(size))
    }

    fn send_one(&self, dest: SocketAddr, contents: &[u8], segment_size: Option<usize>) -> io::Result<()> {
        // No ECN marks and no source address, as before: the same packets on the wire, only fewer system calls.
        let transmit = Transmit { destination: dest, ecn: None, contents, segment_size, src_ip: None };
        self.sock.try_io(Interest::WRITABLE, || self.udp.try_send((&self.sock).into(), &transmit))
    }

    /// Sends to a TURN or STUN server itself (allowed in relay-only mode).
    fn send_server(&self, server: SocketAddr, data: &[u8]) -> io::Result<()> {
        self.counters.relay_out.fetch_add(data.len() as u64, Ordering::Relaxed);
        self.sock.try_send_to(data, self.family(server)).map(|_| ())
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

const SOCKET_BUFFER: usize = 4 << 20;
/// QUIC datagrams waiting outside quinn's buffers (relayed ones, mostly; at most a few batches at a time).
const PENDING_MAX: usize = 4_096;
/// The largest QUIC datagram a relay path carries: 1,280 bytes of UDP payload less the 4-byte ChannelData header.
pub const RELAY_MAX_QUIC: usize = 1_276;
/// The reader used before quinn polls: datagrams per call and room for each (GRO merges up to 64 datagrams).
const BATCH: usize = 4;
const RECV_BUF: usize = 1 << 17;
/// Reads in one quinn poll that only found STUN, TURN or nothing for quinn, before letting other work run.
const RECV_ROUNDS: usize = 64;

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

impl Mux {
    /// QUIC datagrams waiting outside quinn's buffers go into slots `filled..room`; returns the slots now in use.
    fn take_pending(&self, bufs: &mut [IoSliceMut<'_>], meta: &mut [RecvMeta], mut filled: usize, room: usize) -> usize {
        let mut pending = self.pending.lock().unwrap();
        while filled < room {
            let Some(next) = pending.pop_front() else { break };
            let len = next.data.len().min(bufs[filled].len());
            bufs[filled][..len].copy_from_slice(&next.data[..len]);
            // quinn keeps an IPv4 peer of a dual-stack endpoint as its mapped IPv6 address (Endpoint::connect_with),
            // and drops handshake packets from any other form of it: hand IPv4 sources over the same way.
            meta[filled] = RecvMeta { addr: self.family(next.src), len, stride: len, ecn: None, dst_ip: None };
            filled += 1;
        }
        filled
    }

    /// After a read of `n` slots: QUIC from direct senders stays where it landed (moved down over slots handled
    /// here), everything else is handled or queued. Returns how many slots quinn gets.
    fn sort(&self, bufs: &mut [IoSliceMut<'_>], meta: &mut [RecvMeta], n: usize) -> usize {
        let mut kept = 0;
        for i in 0..n {
            let RecvMeta { addr, len, stride, .. } = meta[i];
            let src = canonical(addr);
            let stride = stride.clamp(1, len.max(1));
            // GRO only merges datagrams of one size from one sender; a STUN message among them is still handled.
            let quic_only = !bufs[i][..len].chunks(stride).any(stun::is_stun);
            match quic_only.then(|| self.direct_source(src)).flatten() {
                Some(source) => {
                    self.counters.direct_in.fetch_add(len as u64, Ordering::Relaxed);
                    if kept != i {
                        let (low, high) = bufs.split_at_mut(i);
                        low[kept][..len].copy_from_slice(&high[0][..len]);
                    }
                    meta[kept] = RecvMeta { addr: self.family(source), len, stride, ecn: None, dst_ip: None };
                    kept += 1;
                }
                None => {
                    for segment in bufs[i][..len].chunks(stride) {
                        self.receive(segment, src);
                    }
                }
            }
        }
        kept
    }
}

/// The OS refused a datagram larger than the path (an MTU probe found the limit); not a failure to report.
fn too_big(e: &io::Error) -> bool {
    #[cfg(unix)]
    let code = libc::EMSGSIZE;
    // WSAEMSGSIZE
    #[cfg(windows)]
    let code = 10040;
    e.raw_os_error() == Some(code)
}

impl quinn::AsyncUdpSocket for Mux {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn quinn::UdpPoller>> {
        Box::pin(Poller { mux: self })
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        let dest = canonical(transmit.destination);
        let path = if is_virtual(dest) {
            match self.selected(dest) {
                Some(path) => path,
                None => return Ok(()),
            }
        } else {
            Path::direct(dest)
        };
        match self.send_quic(path, transmit.contents, transmit.segment_size) {
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Err(e),
            // Larger than the path allows (an MTU probe): QUIC treats it as lost and tries a smaller size.
            Err(e) if too_big(&e) => Ok(()),
            // Unreachable networks and the like: QUIC treats the packet as lost.
            Err(e) => {
                self.counters.send_errors.fetch_add(1, Ordering::Relaxed);
                *self.counters.last_send_error.lock().unwrap() = format!("{dest}: {e}");
                Ok(())
            }
            Ok(()) => Ok(()),
        }
    }

    fn poll_recv(&self, cx: &mut Context, bufs: &mut [IoSliceMut<'_>], meta: &mut [RecvMeta]) -> Poll<io::Result<usize>> {
        if !self.attached.swap(true, Ordering::AcqRel) {
            self.attach.notify_one();
        }
        let room = bufs.len().min(meta.len());
        {
            // Before looking at the queue, so a datagram the early reader queues meanwhile still wakes us.
            let mut waker = self.recv_waker.lock().unwrap();
            if !waker.as_ref().is_some_and(|w| w.will_wake(cx.waker())) {
                *waker = Some(cx.waker().clone());
            }
        }
        // As many datagrams as quinn has buffers for, in one call (one wake-up per batch, not per packet).
        let filled = self.take_pending(bufs, meta, 0, room);
        if filled > 0 {
            return Poll::Ready(Ok(filled));
        }
        for _ in 0..RECV_ROUNDS {
            {
                let mut backoff = self.recv_backoff.lock().unwrap();
                if let Some(sleep) = backoff.as_mut() {
                    if sleep.as_mut().poll(cx).is_pending() {
                        return Poll::Pending;
                    }
                    *backoff = None;
                }
            }
            if self.sock.poll_recv_ready(cx)?.is_pending() {
                return Poll::Pending;
            }
            let read = self.sock.try_io(Interest::READABLE, || self.udp.recv((&self.sock).into(), &mut bufs[..room], &mut meta[..room]));
            match read {
                Ok(n) => {
                    let kept = self.sort(bufs, meta, n);
                    let filled = self.take_pending(bufs, meta, kept, room);
                    if filled > 0 {
                        return Poll::Ready(Ok(filled));
                    }
                }
                Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::ConnectionReset) => {}
                // Anything else: pause briefly instead of spinning (as the reader always did); quinn would end the
                // endpoint on an error.
                Err(_) => *self.recv_backoff.lock().unwrap() = Some(Box::pin(tokio::time::sleep(Duration::from_millis(50)))),
            }
        }
        // Only STUN, TURN or junk for a while: let other work run, then carry on.
        cx.waker().wake_by_ref();
        Poll::Pending
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.local)
    }

    fn may_fragment(&self) -> bool {
        self.udp.may_fragment()
    }

    fn max_transmit_segments(&self) -> usize {
        self.udp.max_gso_segments()
    }

    fn max_receive_segments(&self) -> usize {
        self.udp.gro_segments()
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
    use crate::quic::Mtu;

    /// A QUIC handshake to an IPv4 address of a dual-stack endpoint: quinn tracks the server as ::ffff:a.b.c.d, so the
    /// mux must hand its replies over in that form (a Windows PC on IPv4 only never brought a tunnel up before).
    #[tokio::test]
    async fn quic_completes_over_ipv4_on_a_dual_stack_socket() {
        let runtime = Arc::new(quinn::TokioRuntime);
        let server_mux = Mux::bind(0).unwrap();
        let client_mux = Mux::bind(0).unwrap();
        let identity = crate::quic::Identity::generate();
        let server = quinn::Endpoint::new_with_abstract_socket(crate::quic::endpoint_config(), Some(crate::quic::server_config(&identity, crate::quic::Mtu::Base)), server_mux.clone(), runtime.clone()).unwrap();
        let client = quinn::Endpoint::new_with_abstract_socket(crate::quic::endpoint_config(), None, client_mux.clone(), runtime).unwrap();
        let accept = tokio::spawn(async move { server.accept().await.unwrap().await.map(|c| c.remote_address()) });
        let target: SocketAddr = format!("127.0.0.1:{}", server_mux.port()).parse().unwrap();
        let config = crate::quic::client_config(&crate::quic::Identity::generate(), None, Duration::from_secs(5), crate::quic::Mtu::Base);
        let conn = tokio::time::timeout(Duration::from_secs(5), client.connect_with(config, target, "bridgey").unwrap()).await.expect("handshake in time").expect("handshake");
        assert_eq!(canonical(conn.remote_address()), target);
        let seen = tokio::time::timeout(Duration::from_secs(5), accept).await.unwrap().unwrap().unwrap();
        assert_eq!(canonical(seen).ip(), target.ip());
    }

    struct Pair {
        client: quinn::Connection,
        server: quinn::Connection,
        _endpoints: (quinn::Endpoint, quinn::Endpoint),
    }

    /// A QUIC connection from `client_mux` to `target` on `server_mux`, whose server echoes the first stream.
    async fn connect(server_mux: &Arc<Mux>, client_mux: &Arc<Mux>, target: SocketAddr, server_mtu: Mtu, client_mtu: Mtu) -> Pair {
        let runtime = Arc::new(quinn::TokioRuntime);
        let identity = crate::quic::Identity::generate();
        let server = quinn::Endpoint::new_with_abstract_socket(crate::quic::endpoint_config(), Some(crate::quic::server_config(&identity, server_mtu)), server_mux.clone(), runtime.clone()).unwrap();
        let client = quinn::Endpoint::new_with_abstract_socket(crate::quic::endpoint_config(), None, client_mux.clone(), runtime).unwrap();
        let accept = {
            let server = server.clone();
            tokio::spawn(async move { server.accept().await.unwrap().await.unwrap() })
        };
        let config = crate::quic::client_config(&crate::quic::Identity::generate(), None, Duration::from_secs(5), client_mtu);
        let client_conn = tokio::time::timeout(Duration::from_secs(5), client.connect_with(config, target, "bridgey").unwrap()).await.expect("handshake in time").expect("handshake");
        let server_conn = tokio::time::timeout(Duration::from_secs(5), accept).await.unwrap().unwrap();
        let echo = server_conn.clone();
        tokio::spawn(async move {
            let Ok((mut send, mut recv)) = echo.accept_bi().await else { return };
            let mut buf = vec![0u8; 64 << 10];
            while let Ok(Some(n)) = recv.read(&mut buf).await {
                if send.write_all(&buf[..n]).await.is_err() {
                    break;
                }
            }
        });
        Pair { client: client_conn, server: server_conn, _endpoints: (server, client) }
    }

    /// `bytes` out and back through the echo, compared byte for byte.
    async fn echo(send: &mut quinn::SendStream, recv: &mut quinn::RecvStream, bytes: usize, seed: u8) {
        let data: Vec<u8> = (0..bytes).map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed ^ (i >> 8) as u8)).collect();
        let mut back = vec![0u8; bytes];
        let (written, read) = tokio::join!(send.write_all(&data), recv.read_exact(&mut back));
        written.unwrap();
        read.unwrap();
        assert!(back == data, "the echo differs");
    }

    fn loopback(mux: &Mux) -> SocketAddr {
        format!("127.0.0.1:{}", mux.port()).parse().unwrap()
    }

    /// A direct dial finds the path's MTU (1,452 on loopback) while the data stays intact, also against a peer that never
    /// looks, as 1.0.0-beta.1 (MTU discovery off, 1,200 bytes): it acknowledges the probes like any packet.
    #[tokio::test]
    async fn mtu_discovery_on_fixed_paths_and_with_old_peers() {
        let expect = |mtu| if mtu == Mtu::Discover { crate::quic::MAX_UDP } else { 1_200 };
        for (server_mtu, client_mtu) in [(Mtu::Discover, Mtu::Discover), (Mtu::Base, Mtu::Discover), (Mtu::Discover, Mtu::Base), (Mtu::Base, Mtu::Base)] {
            let server_mux = Mux::bind(0).unwrap();
            let client_mux = Mux::bind(0).unwrap();
            let pair = connect(&server_mux, &client_mux, loopback(&server_mux), server_mtu, client_mtu).await;
            let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
            let settled = || pair.client.stats().path.current_mtu == expect(client_mtu) && pair.server.stats().path.current_mtu == expect(server_mtu);
            for round in 0..40u8 {
                echo(&mut send, &mut recv, 256 << 10, round).await;
                if round >= 3 && settled() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            let mtus = (pair.client.stats().path.current_mtu, pair.server.stats().path.current_mtu);
            assert_eq!(mtus, (expect(client_mtu), expect(server_mtu)), "client {client_mtu:?}, server {server_mtu:?}");
            assert_eq!(client_mux.counters.send_errors.load(Ordering::Relaxed) + server_mux.counters.send_errors.load(Ordering::Relaxed), 0);
        }
    }

    const CHANNEL: u16 = 0x4123;

    /// Two muxes whose QUIC connection goes through virtual addresses, as ICE sets up, first on the direct pair; and a
    /// stand-in relay to move it onto: A's ChannelData goes to B unwrapped from the relayed address, B's datagrams to
    /// that address come back to A framed. With `limit`, the relay drops what would exceed it, both ways.
    struct Moving {
        mux_a: Arc<Mux>,
        mux_b: Arc<Mux>,
        va: SocketAddr,
        vb: SocketAddr,
        via_relay: Path,
        relayed: SocketAddr,
        largest: Arc<std::sync::atomic::AtomicUsize>,
        frames: Arc<AtomicU64>,
    }

    async fn moving(limit: Option<usize>) -> Moving {
        let (mux_a, mux_b) = (Mux::bind(0).unwrap(), Mux::bind(0).unwrap());
        let (addr_a, addr_b) = (loopback(&mux_a), loopback(&mux_b));
        let (va, vb) = (mux_a.new_virtual(), mux_b.new_virtual());
        mux_a.map_path(Path::direct(addr_b), va);
        mux_a.select_path(va, Path::direct(addr_b));
        mux_b.map_path(Path::direct(addr_a), vb);
        mux_b.select_path(vb, Path::direct(addr_a));
        let turn = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let relayed = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (server, relayed_addr) = (canonical(turn.local_addr().unwrap()), canonical(relayed.local_addr().unwrap()));
        let largest = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let frames = Arc::new(AtomicU64::new(0));
        let limit = limit.unwrap_or(usize::MAX);
        {
            let (largest, frames) = (largest.clone(), frames.clone());
            tokio::spawn(async move {
                let (mut up, mut down) = (vec![0u8; 65_536], vec![0u8; 65_536]);
                loop {
                    tokio::select! {
                        Ok((n, _)) = turn.recv_from(&mut up) => {
                            largest.fetch_max(n, Ordering::Relaxed);
                            let (number, payload) = stun::parse_channel_data(&up[..n]).expect("ChannelData from the mux");
                            assert_eq!((number, payload.len() + 4), (CHANNEL, n), "one header per datagram");
                            frames.fetch_add(1, Ordering::Relaxed);
                            if n <= limit {
                                let _ = relayed.send_to(payload, addr_b).await;
                            }
                        }
                        Ok((n, _)) = relayed.recv_from(&mut down) => {
                            let framed = stun::channel_data(CHANNEL, &down[..n]);
                            largest.fetch_max(framed.len(), Ordering::Relaxed);
                            if framed.len() <= limit {
                                let _ = turn.send_to(&framed, addr_a).await;
                            }
                        }
                    }
                }
            });
        }
        mux_a.add_turn(server);
        mux_a.bound(server, addr_b, CHANNEL);
        Moving { mux_a, mux_b, va, vb, via_relay: Path { via: Via::Turn(server), remote: addr_b }, relayed: relayed_addr, largest, frames }
    }

    impl Moving {
        /// ICE moves both ends onto the relay: A sends through its allocation, B to A's relayed address.
        fn onto_relay(&self) {
            self.mux_a.map_path(self.via_relay, self.va);
            self.mux_a.select_path(self.va, self.via_relay);
            self.mux_b.map_path(Path::direct(self.relayed), self.vb);
            self.mux_b.select_path(self.vb, Path::direct(self.relayed));
        }
    }

    /// An ICE tunnel moves from a direct pair onto a relay (as when the direct path dies): the data carries on, every
    /// datagram to and from the relay has one ChannelData header and stays within 1,280 bytes, and a datagram too large
    /// for a relay never leaves.
    #[tokio::test]
    async fn ice_tunnel_moves_onto_a_relay_within_its_size() {
        let m = moving(None).await;
        let pair = connect(&m.mux_b, &m.mux_a, m.va, Mtu::Base, Mtu::Base).await;
        let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
        echo(&mut send, &mut recv, 1 << 20, 1).await;
        assert_eq!(m.frames.load(Ordering::Relaxed), 0);
        m.onto_relay();
        tokio::time::timeout(Duration::from_secs(30), echo(&mut send, &mut recv, 4 << 20, 2)).await.expect("the transfer carries on through the relay");
        let frames = m.frames.load(Ordering::Relaxed);
        assert!(frames > 3_000, "the data went through the relay ({frames} frames)");
        m.mux_a.send_quic(m.via_relay, &[0x40; RELAY_MAX_QUIC + 1], None).unwrap();
        m.mux_a.send_quic(m.via_relay, &[0x40; 3 * RELAY_MAX_QUIC], Some(RELAY_MAX_QUIC)).unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        let largest = m.largest.load(Ordering::Relaxed);
        assert!(largest <= 1_280, "largest datagram at the relay: {largest}");
        assert_eq!((pair.client.stats().path.current_mtu, pair.server.stats().path.current_mtu), (1_200, 1_200));
    }

    /// A connection that found a 1,452-byte MTU, whose path then carries no more than 1,280 bytes (a direct dial after
    /// the network changed under it, here a path with that limit): quinn's black-hole detection falls back to 1,200
    /// bytes on both ends and the data carries on.
    #[tokio::test]
    async fn discovered_mtu_falls_back_when_the_path_shrinks() {
        let m = moving(Some(1_280)).await;
        let pair = connect(&m.mux_b, &m.mux_a, m.va, Mtu::Discover, Mtu::Discover).await;
        let (mut send, mut recv) = pair.client.open_bi().await.unwrap();
        let grown = || (pair.client.stats().path.current_mtu, pair.server.stats().path.current_mtu) == (crate::quic::MAX_UDP, crate::quic::MAX_UDP);
        for round in 0..40u8 {
            echo(&mut send, &mut recv, 256 << 10, round).await;
            if grown() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(grown(), "both ends found the larger MTU first");
        m.onto_relay();
        tokio::time::timeout(Duration::from_secs(30), echo(&mut send, &mut recv, 2 << 20, 99)).await.expect("the transfer carries on");
        assert_eq!((pair.client.stats().path.current_mtu, pair.server.stats().path.current_mtu), (1_200, 1_200));
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
