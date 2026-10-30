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

/// Pairs that involve a relay wait this long after checks start, so a direct pair that works (a LAN answers
/// in a few milliseconds) is found first; then both lanes run side by side (happy eyeballs).
pub const RELAY_HEAD_START: Duration = Duration::from_millis(50);
/// First retransmit of a connectivity check.
const CHECK_RTO: Duration = Duration::from_millis(100);

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
    /// The controlling side nominated it; the controlled side selects it once its own check on it passes.
    nominated: bool,
}

/// What the agent reports to its owner.
#[derive(Debug)]
pub enum IceEvent {
    /// The first pair passed a check (the waterfall's "first success").
    FirstSuccess { route: Route },
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
    /// When the remote credentials arrived and checks could start (the relay head start counts from here).
    checks_started: Option<Instant>,
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
                checks_started: None,
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
        st.checks_started.get_or_insert_with(Instant::now);
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
        // A relay pair waits for the permission (or channel) that lets its datagrams through.
        let frozen = matches!(local.via, Via::Turn(server) if !self.mux.can_send(server, remote.addr));
        st.pairs.push(Pair { local: li, remote: ri, pri, state: if frozen { PairState::Frozen } else { PairState::Waiting }, streak: 0, misses: 0, last_ok: None, nominated: false });
        st.pairs.sort_by_key(|p| std::cmp::Reverse(p.pri));
        if frozen {
            if let Via::Turn(server) = local.via {
                let agent = self.clone();
                let peer = remote.addr;
                tokio::spawn(async move { agent.unfreeze_after_bind(server, peer).await });
            }
        }
    }

    /// The owner installs the permission or binds the channel (it holds the allocation); pairs on it are
    /// checked afterwards.
    async fn unfreeze_after_bind(self: Arc<Self>, server: SocketAddr, peer: SocketAddr) {
        for _ in 0..200 {
            if self.mux.can_send(server, peer) {
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
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// The pair goes through a relay on either end.
    fn relayed(st: &State, pair: &Pair) -> bool {
        st.locals[pair.local].kind == "relay" || st.remotes[pair.remote].kind == "relay"
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

    /// Runs every 25 ms: starts the next check in each lane (direct and relayed), nominates, and ends the agent
    /// on timeout.
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
        // The head start is for direct pairs still being checked; with none (relay only, or all failed) it is moot.
        let direct_pending = st.pairs.iter().any(|p| !Self::relayed(&st, p) && matches!(p.state, PairState::Waiting | PairState::InProgress));
        let relay_open = st.checks_started.is_some_and(|t| t.elapsed() >= RELAY_HEAD_START || !direct_pending);
        for relayed in [false, true] {
            if relayed && !relay_open {
                continue;
            }
            if let Some(i) = st.pairs.iter().position(|p| p.state == PairState::Waiting && Self::relayed(&st, p) == relayed) {
                st.pairs[i].state = PairState::InProgress;
                let agent = self.clone();
                let path = Self::path(&st, &st.pairs[i]);
                tokio::spawn(async move { agent.check(i, path, false).await });
            }
        }
        // No nomination step here: until a pair is selected the controlling side nominates aggressively (every check
        // carries USE-CANDIDATE and the first pair that answers is selected); later moves nominate in maintain().
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
        // Aggressive nomination before the first selection (RFC 5245 8.1.1.2): the first pair that answers is the
        // path, with no extra round trip; better pairs found later move QUIC by regular nomination.
        if nominate || (self.controlling && st.selected.is_none()) {
            m.add(stun::ATTR_USE_CANDIDATE, Vec::new());
        }
        Some((m.encode(Some(remote_pwd.as_bytes()), true), m.txid))
    }

    /// One connectivity check on a pair (index into the sorted list at the time it started).
    async fn check(self: Arc<Self>, index: usize, path: Path, nominate: bool) -> bool {
        let (bytes, txid, pwd) = {
            let mut st = self.state.lock().unwrap();
            let Some((bytes, txid)) = self.request(&st, nominate) else {
                // A triggered check before the other side's description arrived (its checks can beat the answer through
                // the control service): no credentials yet, so the pair waits and the tick checks it once they come.
                if let Some(i) = st.pairs.iter().position(|p| Self::path(&st, p) == path) {
                    if st.pairs[i].state == PairState::InProgress {
                        st.pairs[i].state = PairState::Waiting;
                    }
                }
                return false;
            };
            (bytes, txid, st.remote_pwd.clone().unwrap_or_default())
        };
        let started = Instant::now();
        let answer = self.mux.transact_rto(path, &bytes, txid, 6, false, CHECK_RTO).await;
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
                let (route, _) = Self::route(&st, &st.pairs[i]);
                let _ = self.events.send(IceEvent::FirstSuccess { route });
            }
            // Inbound datagrams on a working pair belong to this connection.
            self.mux.map_path(path, self.vaddr);
            let aggressive = self.controlling && st.selected.is_none();
            if nominate || aggressive {
                st.nominating = false;
                self.select(&mut st, i, rtt);
            } else if !self.controlling && st.pairs[i].nominated && self.follows(&st, i) {
                // The controlled side takes a nomination only on a pair its own check proved (RFC 8445 7.3.1.5):
                // a check replayed from another address creates a pair whose check can never pass.
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
        // An older nomination never pulls the path back later.
        for (j, pair) in st.pairs.iter_mut().enumerate() {
            if j != i {
                pair.nominated = false;
            }
        }
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
            None if st.remotes.len() >= 32 => return,
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
        // Datagrams arriving on any pair that passed integrity belong to this connection (QUIC authenticates each one);
        // only where ours leave is guarded by proof.
        self.mux.map_path(path, self.vaddr);
        if nominated && Some(path) != st.selected {
            st.pairs[i].nominated = true;
            if st.selected.is_none() && st.pairs[i].state == PairState::Succeeded {
                self.select(&mut st, i, Duration::ZERO);
                return;
            }
            if st.selected.is_some() && st.pairs[i].state == PairState::Succeeded {
                // A move away from a working path needs a check of our own started after this nomination: a replayed
                // nomination for a pair proven long ago (and dead since) cannot pass one.
                st.pairs[i].state = PairState::InProgress;
                let agent = self.clone();
                tokio::spawn(async move { agent.check(i, path, false).await });
            }
        }
        if Some(path) == st.selected {
            // The controlling side's keep-alive on the selected pair: it still works.
            st.pairs[i].last_ok = Some(Instant::now());
        }
        // Until something is selected, answer QUIC on the first pair that reached us with a valid check (the peer's
        // checks arrive before any replay of them could).
        if st.selected.is_none() && !self.controlling && self.mux.selected(self.vaddr).is_none() {
            self.mux.select_path(self.vaddr, path);
        }
    }

    /// With aggressive nomination several pairs arrive nominated: keep the best one, and follow any move once the
    /// current pair has been quiet for a while (the controlling side replaced a pair that failed).
    fn follows(&self, st: &State, i: usize) -> bool {
        match st.selected.and_then(|sel| st.pairs.iter().find(|p| Self::path(st, p) == sel)) {
            None => true,
            Some(current) => st.pairs[i].pri > current.pri || current.last_ok.is_none_or(|t| t.elapsed() > Duration::from_secs(5)),
        }
    }

    /// The controlling side's keep-alive and upgrade loop, after the first nomination.
    pub async fn maintain(self: Arc<Self>) {
        if !self.controlling {
            return;
        }
        let mut since_upgrade_scan = Duration::ZERO;
        // Right after the first selection (often the relay, which answers first when a direct pair is slow to open)
        // better pairs are tried at 1, 2, 4 and 8 s, so QUIC moves to a direct path within seconds.
        let mut early = [1u64, 1, 2, 4].into_iter();
        loop {
            // A check every 15 s matches the QUIC keep-alive on NATed paths: a radio wake-up shared by both,
            // and 3 misses (45 s) end a pair, as spec 4.6 says. Network changes restart the race at once.
            let wait = Duration::from_secs(early.next().unwrap_or(15));
            tokio::time::sleep(wait).await;
            since_upgrade_scan += wait;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn host(mux: &Mux) -> Local {
        let addr = SocketAddr::new(IpAddr::from([127, 0, 0, 1]), mux.port());
        Local { via: Via::Direct, addr, kind: "host", pri: priority(TYPE_HOST_LAN, addr.ip()), relay: None, net: Some("lan") }
    }

    /// Two agents on loopback: the controlling side selects the first pair that answers, with no separate
    /// nomination round trip (aggressive nomination), and the controlled side follows it.
    #[tokio::test]
    async fn aggressive_nomination_selects_on_first_success() {
        let mux_a = Mux::bind(0).unwrap();
        let mux_b = Mux::bind(0).unwrap();
        let (a, mut events_a) = IceAgent::new(mux_a.clone(), "sid-a".into(), true);
        let (b, mut events_b) = IceAgent::new(mux_b.clone(), "sid-b".into(), false);
        a.add_local(host(&mux_a));
        b.add_local(host(&mux_b));
        a.set_remote_credentials(&b.local_ufrag, &b.local_pwd);
        b.set_remote_credentials(&a.local_ufrag, &a.local_pwd);
        a.add_remote(&host(&mux_b).candidate());
        b.add_remote(&host(&mux_a).candidate());
        let started = Instant::now();
        let selected = |events: &mut mpsc::UnboundedReceiver<IceEvent>| {
            let mut events = std::mem::replace(events, mpsc::unbounded_channel().1);
            async move {
                loop {
                    match events.recv().await {
                        Some(IceEvent::Selected { route, .. }) => return route,
                        Some(_) => continue,
                        None => panic!("agent ended"),
                    }
                }
            }
        };
        let route_a = tokio::time::timeout(Duration::from_secs(2), selected(&mut events_a)).await.expect("A selects");
        let route_b = tokio::time::timeout(Duration::from_secs(2), selected(&mut events_b)).await.expect("B follows");
        assert_eq!((route_a, route_b), (Route::Lan, Route::Lan));
        // Ticks are 25 ms; a direct pair needs no head start, and no 300 ms nomination window is waited out.
        assert!(started.elapsed() < Duration::from_millis(250), "took {:?}", started.elapsed());
        assert!(a.is_selected() && b.is_selected());
    }

    /// A valid nominated check replayed from another address (someone who saw it on the path) creates a pair the
    /// controlled side's own check can never prove, so it is never selected.
    #[tokio::test]
    async fn replayed_nomination_is_not_selected() {
        let mux_a = Mux::bind(0).unwrap();
        let mux_b = Mux::bind(0).unwrap();
        let (a, _events_a) = IceAgent::new(mux_a.clone(), "sid-a".into(), true);
        let (b, _events_b) = IceAgent::new(mux_b.clone(), "sid-b".into(), false);
        b.add_local(host(&mux_b));
        a.set_remote_credentials(&b.local_ufrag, &b.local_pwd);
        b.set_remote_credentials(&a.local_ufrag, &a.local_pwd);
        // A's nominated check, as captured, sent again from the attacker's socket (which never answers B).
        let (bytes, _) = {
            let st = a.state.lock().unwrap();
            a.request(&st, true).unwrap()
        };
        let attacker = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        for _ in 0..3 {
            attacker.send_to(&bytes, ("127.0.0.1", mux_b.port())).await.unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(!b.is_selected());
    }

    /// The controlling side's checks can arrive before the answer reaches the controlled side (the answer goes
    /// through the control service). The controlled side then has no credentials for its triggered check; once
    /// they arrive it must still check, prove the pair and select it.
    #[tokio::test]
    async fn checks_before_the_answer_still_select() {
        let mux_a = Mux::bind(0).unwrap();
        let mux_b = Mux::bind(0).unwrap();
        let (a, _events_a) = IceAgent::new(mux_a.clone(), "sid-a".into(), true);
        let (b, _events_b) = IceAgent::new(mux_b.clone(), "sid-b".into(), false);
        a.add_local(host(&mux_a));
        b.add_local(host(&mux_b));
        a.set_remote_credentials(&b.local_ufrag, &b.local_pwd);
        a.add_remote(&host(&mux_b).candidate());
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(a.is_selected() && !b.is_selected());
        // The answer arrives.
        b.set_remote_credentials(&a.local_ufrag, &a.local_pwd);
        b.add_remote(&host(&mux_a).candidate());
        for _ in 0..40 {
            if b.is_selected() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(b.is_selected());
    }

    #[test]
    fn relay_pairs_are_their_own_lane() {
        let st = State {
            remote_ufrag: None,
            remote_pwd: None,
            locals: vec![
                Local { via: Via::Direct, addr: "192.0.2.1:1".parse().unwrap(), kind: "host", pri: 1, relay: None, net: None },
                Local { via: Via::Turn("198.51.100.1:3478".parse().unwrap()), addr: "198.51.100.1:61000".parse().unwrap(), kind: "relay", pri: 1, relay: None, net: None },
            ],
            remotes: vec![Remote { addr: "192.0.2.2:1".parse().unwrap(), kind: "srflx".into(), pri: 1, relay: None }],
            pairs: Vec::new(),
            selected: None,
            nominating: false,
            first_success: None,
            checks_started: None,
            closed: false,
        };
        let pair = |local| Pair { local, remote: 0, pri: 0, state: PairState::Waiting, streak: 0, misses: 0, last_ok: None, nominated: false };
        assert!(!IceAgent::relayed(&st, &pair(0)));
        assert!(IceAgent::relayed(&st, &pair(1)));
    }
}
