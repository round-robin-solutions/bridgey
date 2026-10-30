//! One UDP socket per node, shared by STUN, TURN and QUIC (spec 7.4, RFC 9443).
//!
//! First byte 0 to 3 is STUN; 64 to 79 from a TURN server we use is ChannelData; anything else is
//! QUIC. Paths found by ICE get a stable virtual address, so quinn sees one peer address while the
//! path underneath moves between pairs (a relay, a direct pair) without dropping the connection.

use crate::addrs::canonical;
use crate::stun::{self, Message};
use std::collections::HashMap;
use std::fmt;
use std::io::{self, IoSliceMut};
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
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
        std_sock.set_nonblocking(true)?;
        let sock = tokio::net::UdpSocket::from_std(std_sock)?;
        let local = sock.local_addr()?;
        let (quic_tx, quic_rx) = mpsc::channel(2_048);
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
                let channel = self.state.lock().unwrap().turns.get(&server).and_then(|c| c.by_peer.get(&path.remote).copied());
                let Some(channel) = channel else { return Ok(()) };
                let framed = stun::channel_data(channel, data);
                self.counters.relay_out.fetch_add(framed.len() as u64, Ordering::Relaxed);
                self.sock.try_send_to(&framed, self.family(server)).map(|_| ())
            }
        }
    }

    /// Sends to a TURN or STUN server itself (allowed in relay-only mode).
    fn send_server(&self, server: SocketAddr, data: &[u8]) -> io::Result<()> {
        self.counters.relay_out.fetch_add(data.len() as u64, Ordering::Relaxed);
        self.sock.try_send_to(data, self.family(server)).map(|_| ())
    }

    /// A STUN transaction with retransmits (250 ms, doubling, `tries` sends).
    pub async fn transact(&self, path: Path, bytes: &[u8], txid: [u8; 12], tries: u32, to_server: bool) -> Option<(Message, Path)> {
        let (tx, mut rx) = oneshot::channel();
        self.state.lock().unwrap().waiters.insert(txid, tx);
        let mut rto = Duration::from_millis(250);
        for _ in 0..tries {
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

    /// The channel number to bind for `peer`: its existing or reserved one, or the next free one.
    pub fn channel_for(&self, server: SocketAddr, peer: SocketAddr) -> u16 {
        let mut state = self.state.lock().unwrap();
        let channels = state.turns.entry(server).or_default();
        if let Some(n) = channels.by_peer.get(&peer).or(channels.reserved.get(&peer)) {
            return *n;
        }
        let n = 0x4000 + (channels.next % 0x0FFF);
        channels.next += 1;
        channels.reserved.insert(peer, n);
        n
    }

    pub fn bound(&self, server: SocketAddr, peer: SocketAddr, number: u16) {
        if let Some(channels) = self.state.lock().unwrap().turns.get_mut(&server) {
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

fn bind_socket(port: u16) -> io::Result<std::net::UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    match Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP)) {
        Ok(socket) => {
            socket.set_only_v6(false)?;
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
            _ => Ok(()),
        }
    }

    fn poll_recv(&self, cx: &mut Context, bufs: &mut [IoSliceMut<'_>], meta: &mut [quinn::udp::RecvMeta]) -> Poll<io::Result<usize>> {
        let mut rx = self.quic_rx.lock().unwrap();
        match rx.poll_recv(cx) {
            Poll::Ready(Some(datagram)) => {
                let len = datagram.data.len().min(bufs[0].len());
                bufs[0][..len].copy_from_slice(&datagram.data[..len]);
                meta[0] = quinn::udp::RecvMeta { addr: datagram.src, len, stride: len, ecn: None, dst_ip: None };
                Poll::Ready(Ok(1))
            }
            Poll::Ready(None) => Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "mux closed"))),
            Poll::Pending => Poll::Pending,
        }
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
