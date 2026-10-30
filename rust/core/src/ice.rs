//! An ICE agent (RFC 8445, trimmed to what Bridgey needs; spec 6.5).
//!
//! Candidates: host (LAN, VPN, global addresses), server-reflexive and relay. Pairs are checked in
//! priority order with STUN Binding requests under short-term credentials. The controlling side
//! (the lower device ID, also the QUIC client) nominates the best pair that answered within a short
//! window, keeps checking better pairs and moves to one that passes three checks in a row, and
//! leaves a pair that misses three checks. QUIC rides on a virtual address, so a move is invisible
//! to it.

use crate::addrs::{self, Route};
use crate::mux::{IceRequest, Mux, Path, Via};
use crate::stun::{self, Message};
use bridgey_connect_proto::signal::Candidate;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

pub const TYPE_HOST_LAN: u32 = 126;
pub const TYPE_HOST_VPN: u32 = 118;
pub const TYPE_HOST_GLOBAL: u32 = 110;
pub const TYPE_PRFLX: u32 = 100;
pub const TYPE_SRFLX: u32 = 90;
pub const TYPE_RELAY: u32 = 2;

pub fn priority(type_pref: u32, ip: IpAddr) -> u32 {
    let local_pref: u32 = if ip.is_ipv6() { 65_535 } else { 65_000 };
    (type_pref << 24) + (local_pref << 8) + 255
}

#[derive(Clone, Debug)]
pub struct Local {
    pub via: Via,
    pub addr: SocketAddr,
    pub kind: &'static str,
    pub pri: u32,
    pub relay: Option<String>,
    pub net: Option<&'static str>,
}

impl Local {
    pub fn candidate(&self) -> Candidate {
        Candidate { k: self.kind.into(), a: self.addr.ip().to_string(), p: self.addr.port(), net: self.net.map(String::from), pri: self.pri, relay: self.relay.clone() }
    }
}

#[derive(Clone, Debug)]
struct Remote {
    addr: SocketAddr,
    kind: String,
    pri: u32,
    relay: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum PairState {
    Frozen,
    Waiting,
    InProgress,
    Succeeded,
    Failed,
}

#[derive(Clone, Debug)]
struct Pair {
    local: usize,
    remote: usize,
    pri: u64,
    state: PairState,
    streak: u32,
    misses: u32,
    last_ok: Option<Instant>,
}

/// What the agent reports to its owner.
#[derive(Debug)]
pub enum IceEvent {
    /// A pair was selected (first time or a move): the route and, for a relay, its ID.
    Selected { route: Route, relay: Option<String>, rtt: Duration },
    /// No pair works any more.
    Failed(&'static str),
}

struct State {
    remote_ufrag: Option<String>,
    remote_pwd: Option<String>,
    locals: Vec<Local>,
    remotes: Vec<Remote>,
    pairs: Vec<Pair>,
    selected: Option<Path>,
    nominating: bool,
    first_success: Option<Instant>,
    closed: bool,
}

pub struct IceAgent {
    pub sid: String,
    pub controlling: bool,
    pub local_ufrag: String,
    pub local_pwd: String,
    pub vaddr: SocketAddr,
    tiebreaker: u64,
    mux: Arc<Mux>,
    state: Mutex<State>,
    events: mpsc::UnboundedSender<IceEvent>,
    started: Instant,
}

fn random_string(len: usize) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bytes = vec![0u8; len];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).expect("random");
    bytes.iter().map(|b| CHARS[(*b as usize) % CHARS.len()] as char).collect()
}

impl IceAgent {
    pub fn new(mux: Arc<Mux>, sid: String, controlling: bool) -> (Arc<IceAgent>, mpsc::UnboundedReceiver<IceEvent>) {
        let (events, rx) = mpsc::unbounded_channel();
        let mut tb = [0u8; 8];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut tb).expect("random");
        let agent = Arc::new(IceAgent {
            sid,
            controlling,
            local_ufrag: random_string(8),
            local_pwd: random_string(24),
            vaddr: mux.new_virtual(),
            tiebreaker: u64::from_be_bytes(tb),
            mux: mux.clone(),
            state: Mutex::new(State {
                remote_ufrag: None,
                remote_pwd: None,
                locals: Vec::new(),
                remotes: Vec::new(),
                pairs: Vec::new(),
                selected: None,
                nominating: false,
                first_success: None,
                closed: false,
            }),
            events,
            started: Instant::now(),
        });
        let (tx, mut requests) = mpsc::unbounded_channel::<IceRequest>();
        mux.register_ice(&agent.local_ufrag, tx);
        let weak = Arc::downgrade(&agent);
        tokio::spawn(async move {
            while let Some(request) = requests.recv().await {
                let Some(agent) = weak.upgrade() else { break };
                agent.on_request(request);
            }
        });
        let ticker = Arc::downgrade(&agent);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(25));
            loop {
                tick.tick().await;
                let Some(agent) = ticker.upgrade() else { break };
                if !agent.tick() {
                    break;
                }
            }
        });
        (agent, rx)
    }

    /// Host candidates from this device's addresses (none when `relay_only`).
    pub fn host_candidates(port: u16) -> Vec<Local> {
        addrs::local_addresses()
            .into_iter()
            .map(|a| {
                let (type_pref, net) = match a.kind {
                    addrs::Kind::Lan => (TYPE_HOST_LAN, "lan"),
                    addrs::Kind::Vpn => (TYPE_HOST_VPN, "vpn"),
                    addrs::Kind::Public6 => (TYPE_HOST_GLOBAL, "public6"),
                };
                Local { via: Via::Direct, addr: SocketAddr::new(a.ip, port), kind: "host", pri: priority(type_pref, a.ip), relay: None, net: Some(net) }
            })
            .take(16)
            .collect()
    }

    pub fn set_remote_credentials(&self, ufrag: &str, pwd: &str) {
        let mut st = self.state.lock().unwrap();
        st.remote_ufrag = Some(ufrag.to_string());
        st.remote_pwd = Some(pwd.to_string());
    }

    pub fn locals(&self) -> Vec<Local> {
        self.state.lock().unwrap().locals.clone()
    }

    pub fn add_local(self: &Arc<Self>, local: Local) {
        let mut st = self.state.lock().unwrap();
        if st.locals.iter().any(|l| l.via == local.via && l.addr == local.addr) {
            return;
        }
        st.locals.push(local);
        let li = st.locals.len() - 1;
        for ri in 0..st.remotes.len() {
            self.pair_up(&mut st, li, ri);
        }
    }

    pub fn add_remote(self: &Arc<Self>, cand: &Candidate) {
        let Some(addr) = cand.a.parse::<IpAddr>().ok().map(|ip| addrs::canonical(SocketAddr::new(ip, cand.p))) else { return };
        if addr.port() == 0 || addr.ip().is_unspecified() || addr.ip().is_multicast() {
            return;
        }
        let mut st = self.state.lock().unwrap();
        if st.remotes.len() >= 32 || st.remotes.iter().any(|r| r.addr == addr) {
            return;
        }
        st.remotes.push(Remote { addr, kind: cand.k.clone(), pri: cand.pri, relay: cand.relay.clone() });
        let ri = st.remotes.len() - 1;
        for li in 0..st.locals.len() {
            self.pair_up(&mut st, li, ri);
        }
    }

    fn pair_up(self: &Arc<Self>, st: &mut State, li: usize, ri: usize) {
        let local = st.locals[li].clone();
        let remote = st.remotes[ri].clone();
        if local.addr.is_ipv4() != remote.addr.is_ipv4() {
            return;
        }
        let (g, d) = if self.controlling { (local.pri, remote.pri) } else { (remote.pri, local.pri) };
        let pri = (1u64 << 32) * u64::from(g.min(d)) + 2 * u64::from(g.max(d)) + u64::from(g > d);
        let frozen = matches!(local.via, Via::Turn(server) if !self.mux.has_channel(server, remote.addr));
        st.pairs.push(Pair { local: li, remote: ri, pri, state: if frozen { PairState::Frozen } else { PairState::Waiting }, streak: 0, misses: 0, last_ok: None });
        st.pairs.sort_by_key(|p| std::cmp::Reverse(p.pri));
        if frozen {
            if let Via::Turn(server) = local.via {
                let agent = self.clone();
                let peer = remote.addr;
                tokio::spawn(async move { agent.unfreeze_after_bind(server, peer).await });
            }
        }
    }

    /// The owner binds the channel (it holds the allocation); pairs on it are checked afterwards.
    async fn unfreeze_after_bind(self: Arc<Self>, server: SocketAddr, peer: SocketAddr) {
        for _ in 0..40 {
            if self.mux.has_channel(server, peer) {
                let mut st = self.state.lock().unwrap();
                let indices: Vec<usize> = (0..st.pairs.len())
                    .filter(|&i| {
                        let p = &st.pairs[i];
                        p.state == PairState::Frozen && st.locals[p.local].via == Via::Turn(server) && st.remotes[p.remote].addr == peer
                    })
                    .collect();
                for i in indices {
                    st.pairs[i].state = PairState::Waiting;
                }
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    fn path(st: &State, pair: &Pair) -> Path {
        Path { via: st.locals[pair.local].via, remote: st.remotes[pair.remote].addr }
    }

    fn route(st: &State, pair: &Pair) -> (Route, Option<String>) {
        let local = &st.locals[pair.local];
        let remote = &st.remotes[pair.remote];
        if local.kind == "relay" {
            return (Route::Relay, local.relay.clone());
        }
        if remote.kind == "relay" {
            return (Route::Relay, remote.relay.clone());
        }
        (addrs::route_of(remote.addr.ip()), None)
    }

    /// Runs every 25 ms: starts the next check, nominates, and ends the agent on timeout.
    fn tick(self: &Arc<Self>) -> bool {
        let mut st = self.state.lock().unwrap();
        if st.closed {
            return false;
        }
        if st.remote_pwd.is_none() {
            return true;
        }
        if st.selected.is_none() && self.started.elapsed() > Duration::from_secs(15) {
            st.closed = true;
            let _ = self.events.send(IceEvent::Failed("timeout"));
            return false;
        }
        if let Some(i) = st.pairs.iter().position(|p| p.state == PairState::Waiting) {
            st.pairs[i].state = PairState::InProgress;
            let agent = self.clone();
            let index = i;
            let pair = st.pairs[i].clone();
            let path = Self::path(&st, &pair);
            tokio::spawn(async move { agent.check(index, path, false).await });
        }
        if self.controlling && st.selected.is_none() && !st.nominating {
            if let Some(first) = st.first_success {
                let best_succeeded = st.pairs.iter().position(|p| p.state == PairState::Succeeded);
                let pending_better = st.pairs.iter().take_while(|p| p.state != PairState::Succeeded).any(|p| matches!(p.state, PairState::Waiting | PairState::InProgress | PairState::Frozen));
                // "First that answers wins", with a 300 ms preference window for a better pair.
                if let Some(best) = best_succeeded {
                    if !pending_better || first.elapsed() >= Duration::from_millis(300) {
                        st.nominating = true;
                        let path = Self::path(&st, &st.pairs[best]);
                        let agent = self.clone();
                        tokio::spawn(async move { agent.check(best, path, true).await });
                    }
                }
            }
        }
        true
    }

    fn request(&self, st: &State, nominate: bool) -> Option<(Vec<u8>, [u8; 12])> {
        let remote_ufrag = st.remote_ufrag.as_ref()?;
        let remote_pwd = st.remote_pwd.as_ref()?;
        let mut m = Message::request(stun::BINDING);
        m.add(stun::ATTR_USERNAME, format!("{remote_ufrag}:{}", self.local_ufrag).into_bytes());
        m.add(stun::ATTR_PRIORITY, priority(TYPE_PRFLX, IpAddr::from([0, 0, 0, 0])).to_be_bytes().to_vec());
        let role = if self.controlling { stun::ATTR_ICE_CONTROLLING } else { stun::ATTR_ICE_CONTROLLED };
        m.add(role, self.tiebreaker.to_be_bytes().to_vec());
        if nominate {
            m.add(stun::ATTR_USE_CANDIDATE, Vec::new());
        }
        Some((m.encode(Some(remote_pwd.as_bytes()), true), m.txid))
    }

    /// One connectivity check on a pair (index into the sorted list at the time it started).
    async fn check(self: Arc<Self>, index: usize, path: Path, nominate: bool) -> bool {
        let (bytes, txid, pwd) = {
            let st = self.state.lock().unwrap();
            let Some((bytes, txid)) = self.request(&st, nominate) else { return false };
            (bytes, txid, st.remote_pwd.clone().unwrap_or_default())
        };
        let started = Instant::now();
        let answer = self.mux.transact(path, &bytes, txid, 6, false).await;
        let ok = matches!(&answer, Some((reply, _)) if reply.class == stun::SUCCESS && reply.verify(pwd.as_bytes()));
        let rtt = started.elapsed();
        let mut st = self.state.lock().unwrap();
        let Some(i) = st.pairs.iter().position(|p| Self::path(&st, p) == path) else { return ok };
        let _ = index;
        if ok {
            let pair = &mut st.pairs[i];
            pair.state = PairState::Succeeded;
            pair.streak += 1;
            pair.misses = 0;
            pair.last_ok = Some(Instant::now());
            if st.first_success.is_none() {
                st.first_success = Some(Instant::now());
            }
            // Inbound datagrams on a working pair belong to this connection.
            self.mux.map_path(path, self.vaddr);
            if nominate {
                st.nominating = false;
                self.select(&mut st, i, rtt);
            }
        } else {
            let pair = &mut st.pairs[i];
            pair.streak = 0;
            pair.misses += 1;
            if pair.state != PairState::Succeeded || pair.misses >= 3 {
                pair.state = PairState::Failed;
            }
            if nominate {
                st.nominating = false;
            }
        }
        ok
    }

    fn select(&self, st: &mut State, i: usize, rtt: Duration) {
        let path = Self::path(st, &st.pairs[i]);
        let changed = st.selected != Some(path);
        st.selected = Some(path);
        self.mux.map_path(path, self.vaddr);
        self.mux.select_path(self.vaddr, path);
        if changed {
            let (route, relay) = Self::route(st, &st.pairs[i]);
            let _ = self.events.send(IceEvent::Selected { route, relay, rtt });
        }
    }

    fn on_request(self: &Arc<Self>, request: IceRequest) {
        let IceRequest { msg, path } = request;
        if !msg.verify(self.local_pwd.as_bytes()) {
            return;
        }
        let expected = msg.string(stun::ATTR_USERNAME).map(|u| u.starts_with(&format!("{}:", self.local_ufrag))).unwrap_or(false);
        if !expected {
            return;
        }
        let mut reply = Message::new(stun::BINDING, stun::SUCCESS, msg.txid);
        reply.add(stun::ATTR_XOR_MAPPED_ADDRESS, stun::encode_xor_address(path.remote, &msg.txid));
        self.mux.reply(path, &reply.encode(Some(self.local_pwd.as_bytes()), true));
        let nominated = msg.has(stun::ATTR_USE_CANDIDATE) && !self.controlling;
        let mut st = self.state.lock().unwrap();
        if st.closed {
            return;
        }
        // The pair the request came in on; an unknown source is a peer-reflexive candidate.
        let li = st.locals.iter().position(|l| l.via == path.via && (l.via != Via::Direct || l.addr.is_ipv4() == path.remote.is_ipv4()));
        let Some(li) = li else { return };
        let ri = match st.remotes.iter().position(|r| r.addr == path.remote) {
            Some(ri) => ri,
            None => {
                let pri = msg.u32(stun::ATTR_PRIORITY).unwrap_or(priority(TYPE_PRFLX, path.remote.ip()));
                st.remotes.push(Remote { addr: path.remote, kind: "prflx".into(), pri, relay: None });
                let ri = st.remotes.len() - 1;
                self.pair_up(&mut st, li, ri);
                ri
            }
        };
        let Some(i) = st.pairs.iter().position(|p| p.local == li && p.remote == ri) else { return };
        if matches!(st.pairs[i].state, PairState::Waiting | PairState::Failed | PairState::Frozen) {
            // Triggered check: this pair works one way, so check it straight away.
            st.pairs[i].state = PairState::InProgress;
            let agent = self.clone();
            tokio::spawn(async move { agent.check(i, path, false).await });
        }
        self.mux.map_path(path, self.vaddr);
        if nominated {
            self.select(&mut st, i, Duration::ZERO);
        } else if st.selected.is_none() && !self.controlling {
            // Until the controlling side nominates, answer QUIC on the pair that reached us.
            self.mux.select_path(self.vaddr, path);
        }
    }

    /// The controlling side's keep-alive and upgrade loop, after the first nomination.
    pub async fn maintain(self: Arc<Self>) {
        if !self.controlling {
            return;
        }
        let mut since_upgrade_scan = Duration::ZERO;
        loop {
            // A check every 15 s matches the QUIC keep-alive on NATed paths: a radio wake-up shared by both,
            // and 3 misses (45 s) end a pair, as spec 4.6 says. Network changes restart the race at once.
            tokio::time::sleep(Duration::from_secs(15)).await;
            since_upgrade_scan += Duration::from_secs(15);
            let (selected_path, better) = {
                let st = self.state.lock().unwrap();
                if st.closed {
                    return;
                }
                let Some(selected) = st.selected else { continue };
                let selected_pri = st.pairs.iter().find(|p| Self::path(&st, p) == selected).map(|p| p.pri).unwrap_or(0);
                let better: Vec<(usize, Path)> = st.pairs.iter().enumerate().filter(|(_, p)| p.pri > selected_pri && p.state != PairState::Frozen).map(|(i, p)| (i, Self::path(&st, p))).collect();
                (selected, better)
            };
            let alive = self.clone().check(0, selected_path, false).await;
            if !alive {
                let replacement = {
                    let st = self.state.lock().unwrap();
                    let selected = st.selected;
                    let missed = st.pairs.iter().find(|p| Some(Self::path(&st, p)) == selected).map(|p| p.misses).unwrap_or(3);
                    if missed < 3 {
                        continue;
                    }
                    st.pairs.iter().position(|p| p.state == PairState::Succeeded && Some(Self::path(&st, p)) != selected && p.last_ok.map(|t| t.elapsed() < Duration::from_secs(30)).unwrap_or(false))
                };
                match replacement {
                    Some(i) => {
                        let path = {
                            let st = self.state.lock().unwrap();
                            Self::path(&st, &st.pairs[i])
                        };
                        let _ = self.clone().check(i, path, true).await;
                    }
                    None => {
                        self.close();
                        let _ = self.events.send(IceEvent::Failed("path_failed"));
                        return;
                    }
                }
                continue;
            }
            // Better pairs: for the first 10 s every tick, then every 60 s; three passes in a row to move.
            let scan = self.started.elapsed() < Duration::from_secs(35) || since_upgrade_scan >= Duration::from_secs(60);
            if scan && !better.is_empty() {
                since_upgrade_scan = Duration::ZERO;
                for (i, path) in better {
                    let mut passes = 0;
                    for _ in 0..3 {
                        if self.clone().check(i, path, false).await {
                            passes += 1;
                        }
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                    if passes == 3 {
                        let _ = self.clone().check(i, path, true).await;
                        break;
                    }
                }
            }
        }
    }

    pub fn close(&self) {
        let mut st = self.state.lock().unwrap();
        if st.closed {
            return;
        }
        st.closed = true;
        self.mux.unregister_ice(&self.local_ufrag);
        self.mux.forget_virtual(self.vaddr);
    }

    pub fn remote_addresses(&self) -> Vec<SocketAddr> {
        self.state.lock().unwrap().remotes.iter().map(|r| r.addr).collect()
    }

    pub fn is_selected(&self) -> bool {
        self.state.lock().unwrap().selected.is_some()
    }
}

impl Drop for IceAgent {
    fn drop(&mut self) {
        self.mux.unregister_ice(&self.local_ufrag);
        self.mux.forget_virtual(self.vaddr);
    }
}
