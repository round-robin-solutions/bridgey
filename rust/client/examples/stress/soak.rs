//! The soak (docs/acceptance-1.0.md): hours of mixed traffic between the peer and the app, with the app's process
//! sampled all along. A clipboard thread sends a text each way every few seconds and checks it arrived; the main loop
//! runs the stress scenarios one at a time at random (whole files of varied sizes both ways, batches of small files,
//! cancels from either end, cuts and stalls with resume, reconnect bursts) with idle periods between them; a sampler
//! asks the app's control program for its process figures (`proc`) every `--sample-every` seconds.
//!
//!   stress soak --app "<program>" --target HOST:PORT --work DIR [--minutes 360] [--max-file 64M] [--sample-every 60]
//!               [--samples FILE] [--report FILE] [--seed N] [--peer-platform ...] [--name ...]
//!
//! Every scenario keeps its own checks (SHA-256 at the receiving end, the right reasons, no partial left, resume
//! offsets), so a soak fails exactly as a stress run would. The report lists every operation with its outcome, the
//! clipboard counts and how every transfer ended; `samples.jsonl` has one line per sample (`kind: app`, with the
//! peer's own figures) and one per operation (`kind: op`). scripts/rr/acceptance.py judges the samples against the
//! thresholds (memory, files, threads, wakeups) and draws the graphs.
//!
//! The app's control program needs, besides the stress verbs: `clipboard-on`, `clip-send <text>` (the app sends that
//! text as Send clipboard does), `clip-status` (`{"text": the newest text it received, "received": count}`) and
//! `proc` (`{"rss_kb", "threads", "fds", ...}`; `gc` as an argument collects garbage first where the app can).

use super::*;

/// The scenarios a soak picks from, with weights. No app restarts: they would reset the very figures a soak watches.
const MIX: &[(&str, u32)] = &[
    ("send-whole", 22),
    ("recv-whole", 22),
    ("small-send", 6),
    ("small-recv", 6),
    ("cancel-peer-send", 4),
    ("cancel-app-recv", 4),
    ("cancel-peer-recv", 4),
    ("cancel-app-send", 4),
    ("drop-send", 6),
    ("drop-recv", 6),
    ("stall-send", 2),
    ("stall-recv", 2),
    ("reconnect", 6),
    ("idle", 6),
];

#[derive(Default)]
struct Clips {
    to_app_sent: u64,
    to_app_delivered: u64,
    to_app_checked: u64,
    to_app_check_failed: u64,
    from_app_sent: u64,
    from_app_arrived: u64,
    /// Not delivered while the link was down, cut or held around that moment: expected, counted apart.
    lost_in_flap: u64,
    /// Not delivered with the link up all along: a failure.
    lost: u64,
    notes: Vec<String>,
    /// How long each read-back took until the app held the text.
    read_back_seconds: Vec<f64>,
}

/// This process's resident memory, threads and open files.
pub fn self_metrics() -> Value {
    let fds = std::fs::read_dir("/dev/fd").map(|d| d.count() as i64).unwrap_or(-1);
    let pid = std::process::id();
    let (rss, threads) = if let Ok(status) = std::fs::read_to_string("/proc/self/status") {
        let field = |name: &str| status.lines().find(|l| l.starts_with(name)).and_then(|l| l.split_whitespace().nth(1)).and_then(|v| v.parse().ok()).unwrap_or(-1i64);
        (field("VmRSS:"), field("Threads:"))
    } else {
        let out = |args: &[&str]| Command::new("ps").args(args).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
        (out(&["-o", "rss=", "-p", &pid.to_string()]).trim().parse().unwrap_or(-1i64), out(&["-M", "-p", &pid.to_string()]).lines().count().saturating_sub(1) as i64)
    };
    json!({"rss_kb": rss, "threads": threads, "fds": fds})
}

struct Flags {
    stop: AtomicBool,
    /// No clipboard traffic now (an idle period).
    quiet: AtomicBool,
    /// A sample is due with a garbage collection first.
    samples: AtomicU64,
}

fn write_line(file: &Mutex<std::fs::File>, v: &Value) {
    let _ = writeln!(file.lock().unwrap(), "{v}");
}

/// A disconnect, a cut or a hold within `window` of `at`: a clip lost then is not the app's fault.
fn flap_near(sh: &Shared, proxy: &ProxyState, at: Instant, window: Duration) -> bool {
    let st = sh.st.lock().unwrap();
    let recent = st.last_disconnect.as_ref().is_some_and(|(t, _)| t.saturating_duration_since(at) < window && at.saturating_duration_since(*t) < window);
    recent || st.connected.is_none() || proxy.hold.load(Ordering::SeqCst)
}

#[allow(clippy::too_many_arguments)]
fn clip_loop(client: Arc<Client>, sh: Arc<Shared>, proxy: Arc<ProxyState>, app: App, device: String, flags: Arc<Flags>, clips: Arc<Mutex<Clips>>, seed: u64) {
    let mut rng = Rng(Gen(seed ^ 0xC11B));
    let mut seq = 0u64;
    while !flags.stop.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(3000 + rng.below(5000)));
        if flags.quiet.load(Ordering::SeqCst) || flags.stop.load(Ordering::SeqCst) {
            continue;
        }
        seq += 1;
        let text = format!("soak clip {seq} {:016x}", rng.0.next());
        let at = Instant::now();
        if seq % 2 == 1 {
            // Here to the app: delivered (the app's ack), and now and then read back from the app.
            clips.lock().unwrap().to_app_sent += 1;
            let delivered = client.send_clipboard(&device, &text).ok().and_then(|req| sh.wait(Duration::from_secs(10), |st| st.clip_results.remove(&req)));
            let ok = delivered.as_deref() == Some("delivered");
            let mut c = clips.lock().unwrap();
            if ok {
                c.to_app_delivered += 1;
                drop(c);
                if seq % 5 == 1 {
                    // Read back from the app, for up to three seconds: the Mac test instance reports its pasteboard in a
                    // status file it rewrites five times a second, so the first read can come before the write.
                    let t0 = Instant::now();
                    let got = loop {
                        let held = app.verb("clip-status").ok().and_then(|v| v.get("text").and_then(Value::as_str).map(str::to_string));
                        if held.as_deref() == Some(text.as_str()) || t0.elapsed() >= Duration::from_secs(3) {
                            break held;
                        }
                        std::thread::sleep(Duration::from_millis(200));
                    };
                    let mut c = clips.lock().unwrap();
                    c.to_app_checked += 1;
                    c.read_back_seconds.push(secs(t0.elapsed()));
                    if got.as_deref() != Some(text.as_str()) && !flap_near(&sh, &proxy, at, Duration::from_secs(10)) {
                        c.to_app_check_failed += 1;
                        if c.notes.len() < 50 {
                            c.notes.push(format!("{}s: the app holds {:?}, sent {text:?}", secs(sh.t0.elapsed()), got));
                        }
                    }
                }
            } else if flap_near(&sh, &proxy, at, Duration::from_secs(15)) {
                c.lost_in_flap += 1;
            } else {
                c.lost += 1;
                if c.notes.len() < 50 {
                    c.notes.push(format!("{}s: to the app {:?} ({delivered:?})", secs(sh.t0.elapsed()), text));
                }
            }
        } else {
            // The app to here: it sends the text as Send clipboard does.
            clips.lock().unwrap().from_app_sent += 1;
            let asked = app.call("clip-send", std::slice::from_ref(&text));
            let arrived = asked.is_ok() && sh.wait(Duration::from_secs(10), |st| st.clips_in.iter().any(|(_, t)| t == &text).then_some(())).is_some();
            let mut c = clips.lock().unwrap();
            if arrived {
                c.from_app_arrived += 1;
            } else if flap_near(&sh, &proxy, at, Duration::from_secs(15)) {
                c.lost_in_flap += 1;
            } else {
                c.lost += 1;
                if c.notes.len() < 50 {
                    c.notes.push(format!("{}s: from the app {:?} ({:?})", secs(sh.t0.elapsed()), text, asked.err()));
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn sample_loop(app: App, sh: Arc<Shared>, flags: Arc<Flags>, clips: Arc<Mutex<Clips>>, out: Arc<Mutex<std::fs::File>>, every: Duration, gc_every: u64) {
    let mut next = Instant::now();
    while !flags.stop.load(Ordering::SeqCst) {
        if Instant::now() < next {
            std::thread::sleep(Duration::from_millis(250));
            continue;
        }
        next += every;
        let n = flags.samples.fetch_add(1, Ordering::SeqCst);
        let gc = n.is_multiple_of(gc_every);
        let args: Vec<String> = if gc { vec!["gc".into()] } else { Vec::new() };
        let t = secs(sh.t0.elapsed());
        let app_figures = app.call("proc", &args).unwrap_or_else(|e| json!({"error": e}));
        let (connected, disconnects, errors) = {
            let st = sh.st.lock().unwrap();
            (st.connected.is_some(), st.disconnects, st.errors)
        };
        let c = clips.lock().unwrap();
        let line = json!({"kind": "app", "t": t, "gc": gc, "idle": flags.quiet.load(Ordering::SeqCst), "connected": connected,
            "app": app_figures, "peer": self_metrics(), "disconnects": disconnects, "peer_errors": errors,
            "clips": {"to_app": c.to_app_delivered, "from_app": c.from_app_arrived, "lost": c.lost, "lost_in_flap": c.lost_in_flap}});
        drop(c);
        write_line(&out, &line);
    }
}

pub fn main(args: &[String]) -> i32 {
    let flags = match parse_flags(args, &["--minutes", "--max-file", "--sample-every", "--samples"]) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("soak: {e}");
            return 2;
        }
    };
    let minutes: u64 = flags.get("--minutes").and_then(|v| v.parse().ok()).unwrap_or(360);
    let max_file = flags.get("--max-file").map(|v| parse_size(v)).unwrap_or(64 * MIB).max(MIB);
    let every = Duration::from_secs(flags.get("--sample-every").and_then(|v| v.parse().ok()).unwrap_or(60).max(5));
    let mut run = match start_run(&flags, true) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("soak: {e}");
            return 2;
        }
    };
    let work = run.cfg.state.parent().unwrap_or(Path::new(".")).to_path_buf();
    let report_path = flags.get("--report").map(PathBuf::from).unwrap_or_else(|| work.join("soak.json"));
    let samples_path = flags.get("--samples").map(PathBuf::from).unwrap_or_else(|| work.join("samples.jsonl"));
    let samples = Arc::new(Mutex::new(std::fs::File::create(&samples_path).expect("samples file")));
    let sh = run.sh.clone();
    let seed = run.opts.seed;
    sh.note(json!({"event": "soak", "seed": seed, "minutes": minutes}));

    let mut pair_sc = Scenario { name: "pair".into(), t0: Instant::now(), failures: Vec::new(), metrics: Map::new(), rounds: Vec::new() };
    let setup = (|| -> Step {
        pair(&mut run, &mut pair_sc)?;
        if !pair_sc.failures.is_empty() {
            return Err(pair_sc.failures.join("; "));
        }
        run.app.verb("clipboard-on")?;
        run.settle()
    })();
    if let Err(e) = setup {
        eprintln!("soak: setting up: {e}");
        let _ = std::fs::write(&report_path, serde_json::to_string_pretty(&json!({"tool": "bridgey-soak", "ok": false, "failures": [format!("setup: {e}")]})).unwrap());
        return 1;
    }
    let device = run.device.clone().unwrap_or_default();
    let started = now_unix();
    let t_start = Instant::now();
    let deadline = t_start + Duration::from_secs(minutes * 60);
    let flags_shared = Arc::new(Flags { stop: AtomicBool::new(false), quiet: AtomicBool::new(false), samples: AtomicU64::new(0) });
    let clips = Arc::new(Mutex::new(Clips::default()));
    let sampler = {
        let (app, sh, f, c, out) = (App { program: run.app.program.clone(), args: run.app.args.clone() }, sh.clone(), flags_shared.clone(), clips.clone(), samples.clone());
        std::thread::spawn(move || sample_loop(app, sh, f, c, out, every, 5))
    };
    let clipper = {
        let (client, sh, proxy, app, f, c) =
            (run.client.clone(), sh.clone(), run.proxy.st.clone(), App { program: run.app.program.clone(), args: run.app.args.clone() }, flags_shared.clone(), clips.clone());
        let device = device.clone();
        std::thread::spawn(move || clip_loop(client, sh, proxy, app, device, f, c, seed))
    };

    let total_weight: u64 = MIX.iter().map(|(_, w)| *w as u64).sum();
    let mut ops: Vec<Value> = Vec::new();
    let mut failed_ops = 0usize;
    // A long quiet period every hour, the first one early enough that a short run has one too.
    let mut next_long_idle = t_start + Duration::from_secs((55 * 60).min(minutes * 60 * 2 / 5));
    let long_idle = Duration::from_secs((10 * 60).min(minutes * 6).max(120));
    let mut stopped = None;
    while Instant::now() < deadline {
        let left = deadline.saturating_duration_since(Instant::now());
        let (op, idle_for) = if Instant::now() >= next_long_idle {
            next_long_idle += Duration::from_secs(60 * 60);
            ("long-idle", Some(long_idle.min(left)))
        } else {
            let mut pick = run.rng.below(total_weight);
            let op = MIX.iter().find(|(_, w)| {
                if pick < *w as u64 {
                    true
                } else {
                    pick -= *w as u64;
                    false
                }
            });
            let op = op.map(|(n, _)| *n).unwrap_or("send-whole");
            (op, (op == "idle").then(|| Duration::from_secs(180 + run.rng.below(180)).min(left)))
        };
        let t0 = Instant::now();
        let at = secs(sh.t0.elapsed());
        let mut sc = Scenario { name: op.into(), t0, failures: Vec::new(), metrics: Map::new(), rounds: Vec::new() };
        // Sizes: mostly small and medium, now and then up to the largest the device takes.
        let size = match run.rng.below(10) {
            0..=3 => 4096 + run.rng.below(4 * MIB),
            4..=7 => 4 * MIB + run.rng.below(max_file / 2),
            _ => max_file / 2 + run.rng.below(max_file / 2),
        }
        .min(max_file);
        let mid = (size.max(8 * MIB) / MIB) * MIB;
        run.opts.rounds = 1;
        run.opts.mid = mid;
        run.opts.small = 8 + run.rng.below(25) as usize;
        run.opts.loops = 3;
        let outcome = if let Some(idle) = idle_for {
            flags_shared.quiet.store(true, Ordering::SeqCst);
            sc.metric("idle_seconds", idle.as_secs());
            std::thread::sleep(idle);
            flags_shared.quiet.store(false, Ordering::SeqCst);
            // Still connected after the quiet: heartbeats kept the session up.
            sc.check(run.connected(), "the session ended during the idle period");
            Ok(())
        } else {
            match op {
                "send-whole" => send_whole(&mut run, &mut sc, size),
                "recv-whole" => recv_whole(&mut run, &mut sc, size),
                "small-send" => small(&mut run, &mut sc, false),
                "small-recv" => small(&mut run, &mut sc, true),
                "reconnect" => reconnect_loop(&mut run, &mut sc),
                // cancel-*, drop-*, stall-*: the stress scenario of that name, one round at `mid`.
                _ => run_scenario(&mut run, &mut sc),
            }
        };
        if let Err(e) = &outcome {
            sc.failures.push(format!("stopped: {e}"));
        }
        if let Err(e) = run.settle() {
            sc.failures.push(format!("afterwards: {e}"));
        }
        // Sources are made per size, and a soak picks a new size each time: keep the disk from filling.
        if let Ok(d) = std::fs::read_dir(&run.src) {
            for e in d.flatten() {
                let _ = std::fs::remove_file(e.path());
            }
        }
        run.sources.clear();
        run.expected.clear();
        let ok = sc.failures.is_empty();
        if !ok {
            failed_ops += 1;
            eprintln!("  soak {op} at {at}s FAILED: {:?}", sc.failures);
        }
        let mut entry = json!({"kind": "op", "t": at, "op": op, "ok": ok, "seconds": secs(t0.elapsed()), "size": if idle_for.is_some() { Value::Null } else { json!(size) },
            "failures": sc.failures, "metrics": sc.metrics});
        if !sc.rounds.is_empty() {
            entry["rounds"] = Value::Array(sc.rounds.clone());
        }
        write_line(&samples, &entry);
        ops.push(entry);
        if !run.connected() && run.ensure_connected(Duration::from_secs(180)).is_err() {
            stopped = Some(format!("cannot reach the app any more after {op} at {at}s"));
            eprintln!("soak: {}", stopped.as_deref().unwrap_or(""));
            break;
        }
        // A gap between operations; the clipboard keeps going.
        let gap = Duration::from_secs(15 + run.rng.below(45)).min(deadline.saturating_duration_since(Instant::now()));
        std::thread::sleep(gap);
    }
    flags_shared.stop.store(true, Ordering::SeqCst);
    let _ = clipper.join();
    let _ = sampler.join();
    // One last sample after a collection, so the end of the run is compared like for like.
    let last = run.app.call("proc", &["gc".to_string()]).unwrap_or_else(|e| json!({"error": e}));
    write_line(&samples, &json!({"kind": "app", "t": secs(sh.t0.elapsed()), "gc": true, "idle": false, "final": true, "app": last, "peer": self_metrics()}));

    let st = sh.st.lock().unwrap();
    let mut outcomes: HashMap<String, u64> = HashMap::new();
    let mut unfinished = Vec::new();
    for (id, t) in st.transfers.iter() {
        let key = match (&t.ended, t.done, &t.failed) {
            (Some(_), true, _) => "done".to_string(),
            (Some(_), _, Some(reason)) => reason.clone(),
            (Some(_), _, None) => "ended".to_string(),
            (None, ..) => {
                unfinished.push(json!({"transfer": id, "name": t.name, "bytes": t.bytes, "total": t.total}));
                "unfinished".to_string()
            }
        };
        *outcomes.entry(key).or_default() += 1;
    }
    let other_endings: u64 = outcomes.iter().filter(|(k, _)| !["done", "cancelled", "cancelled_remote", "interrupted"].contains(&k.as_str())).map(|(_, v)| *v).sum();
    let c = clips.lock().unwrap();
    let mut failures: Vec<String> = Vec::new();
    if let Some(s) = &stopped {
        failures.push(s.clone());
    }
    if failed_ops > 0 {
        failures.push(format!("{failed_ops} of {} operations failed", ops.len()));
    }
    if other_endings > 0 {
        failures.push(format!("{other_endings} transfers ended other than done, cancelled or interrupted: {outcomes:?}"));
    }
    if c.lost > 0 || c.to_app_check_failed > 0 {
        failures.push(format!("clipboard: {} lost with the link up, {} read back wrong", c.lost, c.to_app_check_failed));
    }
    if st.dropped > 0 {
        failures.push(format!("the peer's event queue dropped {} events", st.dropped));
    }
    let doc = json!({
        "tool": "bridgey-soak", "ok": failures.is_empty(), "started": started, "finished": now_unix(), "seed": seed,
        "minutes_planned": minutes, "minutes_run": (t_start.elapsed().as_secs_f64() / 6.0).round() / 10.0,
        "target": run.opts.target.to_string(), "peer_platform": run.cfg.platform, "max_file": max_file,
        "failures": failures,
        "operations": {"total": ops.len(), "failed": failed_ops},
        "clipboard": {"to_app_sent": c.to_app_sent, "to_app_delivered": c.to_app_delivered, "to_app_checked": c.to_app_checked,
            "to_app_check_failed": c.to_app_check_failed, "from_app_sent": c.from_app_sent, "from_app_arrived": c.from_app_arrived,
            "lost_in_flap": c.lost_in_flap, "lost": c.lost, "notes": c.notes,
            "read_back_seconds": {"n": c.read_back_seconds.len(), "max": c.read_back_seconds.iter().cloned().fold(0.0, f64::max),
                "mean": if c.read_back_seconds.is_empty() { 0.0 } else { c.read_back_seconds.iter().sum::<f64>() / c.read_back_seconds.len() as f64 }}},
        "transfers": {"outcomes": outcomes, "unfinished": unfinished},
        "peer": {"disconnects": st.disconnects, "errors": st.errors, "dropped": st.dropped, "pairing_prompts": st.pairing_prompts,
            "proxy_connections": run.proxy.st.accepted.load(Ordering::Relaxed)},
        "samples": samples_path.display().to_string(),
        "ops": ops,
    });
    drop(c);
    drop(st);
    let _ = std::fs::write(&report_path, serde_json::to_string_pretty(&doc).unwrap());
    run.client.stop();
    eprintln!("soak report: {} ({})", report_path.display(), if doc["ok"] == json!(true) { "ok" } else { "FAILED" });
    if doc["ok"] == json!(true) {
        0
    } else {
        1
    }
}
