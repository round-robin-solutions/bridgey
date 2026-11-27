//! Upgrade acceptance (docs/acceptance-1.0.md): the peer sets up an older build of the app the way a person would have
//! it, has the app upgraded in place in the middle of a transfer, and checks that the new build kept everything.
//!
//!   stress accept --app "<program>" --target HOST:PORT --work DIR [--mid 192M] [--report FILE]
//!
//! Before: pairs with the freshly installed older build (it must ask: a new install), turns Clipboard on, moves texts
//! and files both ways (activity and transfer history), sets per-device grants (`grants`: screen, control,
//! Unattended access off) and non-default settings (`settings`, which restarts the app), and leaves a kept partial: a
//! file to the app cut at about 40 % (its resume record). Then `snapshot before.json`, a second file to the app, and
//! `upgrade` while that file is moving (the installer ends the old process mid-file, as a real update does).
//! After: `snapshot after.json` straight away, then the peer must reconnect with no pairing prompt and the same device
//! ID, both partials must be on the app and resume from their verified bytes (the cut one losing at most what a clean
//! cut may, the one the upgrade killed at most its last checkpoint), and texts and files must still move both ways.
//! `snapshot after-traffic.json` closes the run. scripts/rr/acceptance.py compares the snapshots (settings, grants,
//! trust, history, resume records, version).
//!
//! The app's control program needs, besides the stress verbs: `clipboard-on`, `clip-send`, `clip-status` (as the soak),
//! `grants`, `settings`, `snapshot <file>` and `upgrade` (returns `{"from": <version>, "to": <version>}`).

use super::*;

fn clip_both_ways(run: &mut Run, sc: &mut Scenario, label: &str) {
    let device = match run.device() {
        Ok(d) => d,
        Err(e) => return sc.check(false, e),
    };
    for i in 0..2 {
        let text = format!("acceptance {label} to app {i} {:08x}", run.rng.0.next() as u32);
        let delivered = run.client.send_clipboard(&device, &text).ok().and_then(|req| run.sh.wait(Duration::from_secs(15), |st| st.clip_results.remove(&req)));
        sc.check(delivered.as_deref() == Some("delivered"), format!("{label}: clipboard to the app: {delivered:?}"));
        let (held, _) = run.app_clip_holds(&text, Duration::from_secs(3));
        sc.check(held.as_deref() == Some(text.as_str()), format!("{label}: the app holds {held:?}, sent {text:?}"));
        let back = format!("acceptance {label} from app {i} {:08x}", run.rng.0.next() as u32);
        let asked = run.app.call("clip-send", std::slice::from_ref(&back));
        let arrived = asked.is_ok() && run.sh.wait(Duration::from_secs(15), |st| st.clips_in.iter().any(|(_, t)| t == &back).then_some(())).is_some();
        sc.check(arrived, format!("{label}: clipboard from the app did not arrive ({:?})", asked.err()));
    }
}

/// Sends a file from here and cuts the link once `fraction` of it moved; returns (name, size, seed, bytes at the cut).
fn cut_send(run: &mut Run, sc: &mut Scenario, tag: &str, fraction: f64) -> Result<(String, u64, u64, u64), String> {
    let size = run.opts.mid;
    let seed = run.seed();
    let name = run.name(tag);
    let (path, _) = run.source(size, seed)?;
    run.proxy.limit(size / 6);
    let id = run.send(&path, &name)?;
    let reached = run.wait_bytes(id, (size as f64 * fraction) as u64, run.timeout_for(size))?;
    run.proxy.cut();
    let t = run.wait_end(id, Duration::from_secs(30))?;
    run.proxy.limit(0);
    sc.check(!t.done, format!("{name}: finished before the cut"));
    sc.check(t.failed.as_deref() == Some("interrupted"), format!("{name}: ended with {:?}, expected interrupted", t.failed));
    run.wait_disconnected(Duration::from_secs(15));
    Ok((name, size, seed, t.bytes.max(reached)))
}

#[allow(clippy::too_many_arguments)]
/// Sends a kept file again; it must resume from a whole block no further back than `allowed` and arrive whole.
fn resume(run: &mut Run, sc: &mut Scenario, what: &str, name: &str, size: u64, seed: u64, at_cut: u64, allowed: u64) -> Value {
    let (path, sha) = match run.source(size, seed) {
        Ok(s) => s,
        Err(e) => {
            sc.check(false, format!("{what}: {e}"));
            return json!({"error": e});
        }
    };
    let id = match run.send(&path, name) {
        Ok(id) => id,
        Err(e) => {
            sc.check(false, format!("{what}: {e}"));
            return json!({"error": e});
        }
    };
    let t = match run.wait_end(id, run.timeout_for(size)) {
        Ok(t) => t,
        Err(e) => {
            sc.check(false, format!("{what}: {e}"));
            return json!({"error": e});
        }
    };
    let resumed = t.resumed_at.unwrap_or(0);
    let lost = at_cut.saturating_sub(resumed);
    sc.check(t.done, format!("{what}: {:?}", t.failed));
    sc.check(resumed > 0, format!("{what}: started again from zero (cut at {} MiB)", mb(at_cut)));
    sc.check(lost <= allowed, format!("{what}: resumed {} MiB before the cut, more than {} MiB", mb(lost), mb(allowed)));
    if t.done {
        run.check_app_copy(sc, name, size, &sha);
    }
    json!({"name": name, "size": size, "cut_at_mib": mb(at_cut), "resumed_at_mib": mb(resumed), "lost_mib": mb(lost), "allowed_mib": mb(allowed),
        "done": t.done, "seconds": t.moving.zip(t.ended).map(|(a, b)| secs(b - a))})
}

/// Records a step; returns whether it passed.
fn finish(mut sc: Scenario, outcome: Step, steps: &mut Vec<Value>, failed: &mut usize) -> bool {
    if let Err(e) = outcome {
        sc.failures.push(format!("stopped: {e}"));
    }
    let ok = sc.failures.is_empty();
    if !ok {
        *failed += 1;
    }
    eprintln!("== {}: {}", sc.name, if ok { "ok".to_string() } else { format!("FAILED {:?}", sc.failures) });
    let mut entry = json!({"name": sc.name, "ok": ok, "seconds": secs(sc.t0.elapsed()), "failures": sc.failures, "metrics": sc.metrics});
    if !sc.rounds.is_empty() {
        entry["rounds"] = Value::Array(sc.rounds);
    }
    steps.push(entry);
    ok
}

fn snapshot(run: &Run, sc: &mut Scenario, work: &Path, file: &str) {
    let path = work.join(file);
    if let Err(e) = run.app.call("snapshot", &[path.display().to_string()]) {
        sc.check(false, format!("snapshot {file}: {e}"));
    }
}

pub fn main(args: &[String]) -> i32 {
    let mut flags = match parse_flags(args, &[]) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("accept: {e}");
            return 2;
        }
    };
    flags.entry("--mid".into()).or_insert_with(|| "192M".into());
    let mut run = match start_run(&flags, true) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("accept: {e}");
            return 2;
        }
    };
    let work = run.cfg.state.parent().unwrap_or(Path::new(".")).to_path_buf();
    let report = flags.get("--report").map(PathBuf::from).unwrap_or_else(|| work.join("accept.json"));
    let started = now_unix();
    let mut steps: Vec<Value> = Vec::new();
    let mut failed = 0usize;
    let new_sc = |name: &str| Scenario { name: name.into(), t0: Instant::now(), failures: Vec::new(), metrics: Map::new(), rounds: Vec::new() };

    // 1. The older build, set up as it would be in use.
    let mut sc = new_sc("before: pair");
    let out = pair(&mut run, &mut sc);
    sc.check(sc.metrics.get("mode") == Some(&json!("paired")), "the older build did not ask to pair: not a fresh install");
    let paired_device = run.device.clone();
    if !finish(sc, out, &mut steps, &mut failed) || paired_device.is_none() {
        return write_report(&report, started, &run, steps, failed, "not paired");
    }
    let mut sc = new_sc("before: clipboard, files, grants, settings");
    let out = (|| -> Step {
        run.app.verb("clipboard-on")?;
        run.settle()?;
        clip_both_ways(&mut run, &mut sc, "before");
        send_whole(&mut run, &mut sc, 3 * MIB + 17)?;
        recv_whole(&mut run, &mut sc, 2 * MIB + 5)?;
        run.app.verb("grants")?;
        // Non-default settings; the app restarts to read them, then the peer comes back.
        run.app.verb("settings")?;
        run.ensure_connected(Duration::from_secs(120))?;
        Ok(())
    })();
    finish(sc, out, &mut steps, &mut failed);

    let mut sc = new_sc("before: kept partial");
    let mut kept = None;
    let out = (|| -> Step {
        run.settle()?;
        let k = cut_send(&mut run, &mut sc, "akeep", 0.4)?;
        run.ensure_connected(Duration::from_secs(120))?;
        let partials = run.app_partials()?;
        sc.check(partials.len() == 1, format!("the app keeps {partials:?}, expected one partial"));
        sc.metric("kept", json!({"name": k.0, "cut_at_mib": mb(k.3)}));
        kept = Some(k);
        Ok(())
    })();
    finish(sc, out, &mut steps, &mut failed);

    // 2. The upgrade, in the middle of a second file.
    let mut sc = new_sc("upgrade mid-file");
    let mut pending = None;
    let prompts_before = run.sh.st.lock().unwrap().pairing_prompts;
    let out = (|| -> Step {
        // Settle every write the older build makes after the traffic before the snapshot.
        std::thread::sleep(Duration::from_secs(3));
        snapshot(&run, &mut sc, &work, "before.json");
        let size = run.opts.mid;
        let seed = run.seed();
        let name = run.name("aupgrade");
        let (path, _) = run.source(size, seed)?;
        run.proxy.limit(size / 8);
        let id = run.send(&path, &name)?;
        // Past the receiver's first 64 MiB checkpoint, so the kill leaves something to resume.
        let reached = run.wait_bytes(id, (80 * MIB).max(size / 2).min(size * 3 / 4), run.timeout_for(size))?;
        let t_up = Instant::now();
        let answer = run.app.verb("upgrade")?;
        sc.metric("upgrade", answer.clone());
        sc.metric("upgrade_seconds", secs(t_up.elapsed()));
        let from = answer.get("from").and_then(Value::as_str).unwrap_or("");
        let to = answer.get("to").and_then(Value::as_str).unwrap_or("");
        sc.check(!from.is_empty() && !to.is_empty() && from != to, format!("the upgrade went from {from:?} to {to:?}"));
        let t = run.wait_end(id, Duration::from_secs(60))?;
        run.proxy.limit(0);
        sc.check(!t.done, "the file finished before the upgrade");
        pending = Some((name, size, seed, t.bytes.max(reached)));
        snapshot(&run, &mut sc, &work, "after.json");
        Ok(())
    })();
    finish(sc, out, &mut steps, &mut failed);

    // 3. The new build.
    let mut sc = new_sc("after: reconnect without pairing");
    let out = (|| -> Step {
        let s = run.ensure_connected(Duration::from_secs(120))?;
        sc.metric("reconnect_seconds", s);
        let prompts = run.sh.st.lock().unwrap().pairing_prompts;
        sc.check(prompts == prompts_before, format!("{} pairing prompt(s) after the upgrade", prompts - prompts_before));
        let connected = run.sh.st.lock().unwrap().connected.clone();
        sc.check(connected == paired_device, format!("connected to {connected:?}, paired with {paired_device:?}"));
        let features = run.sh.st.lock().unwrap().features.clone().unwrap_or(Value::Null);
        for key in ["files", "files_fast_draft1", "files_resume_draft1", "clipboard"] {
            sc.check(features.get(key).and_then(Value::as_bool) == Some(true), format!("the new build does not show {key}"));
        }
        let partials = run.app_partials()?;
        sc.metric("partials", json!(partials));
        sc.check(partials.len() == 2, format!("the app keeps {partials:?}, expected the two partials"));
        Ok(())
    })();
    finish(sc, out, &mut steps, &mut failed);

    let mut sc = new_sc("after: kept partials resume");
    let out: Step = {
        if let Some((name, size, seed, at)) = kept.clone() {
            let r = resume(&mut run, &mut sc, "the partial kept before the upgrade", &name, size, seed, at, CUT_LOSS);
            sc.rounds.push(r);
        } else {
            sc.check(false, "no kept partial from before");
        }
        if let Some((name, size, seed, at)) = pending.clone() {
            let r = resume(&mut run, &mut sc, "the file the upgrade interrupted", &name, size, seed, at, KILL_LOSS);
            sc.rounds.push(r);
        } else {
            sc.check(false, "no interrupted file from the upgrade");
        }
        let (active, partials) = run.app_settled(Duration::from_secs(15));
        sc.check(active == 0 && partials.is_empty(), format!("after resuming, the app shows {active} running and partials {partials:?}"));
        Ok(())
    };
    finish(sc, out, &mut steps, &mut failed);

    let mut sc = new_sc("after: clipboard and files");
    let out = (|| -> Step {
        run.settle()?;
        clip_both_ways(&mut run, &mut sc, "after");
        send_whole(&mut run, &mut sc, 4 * MIB + 3)?;
        recv_whole(&mut run, &mut sc, 3 * MIB + 9)?;
        run.settle()?;
        std::thread::sleep(Duration::from_secs(3));
        snapshot(&run, &mut sc, &work, "after-traffic.json");
        Ok(())
    })();
    finish(sc, out, &mut steps, &mut failed);
    write_report(&report, started, &run, steps, failed, "")
}

fn write_report(path: &Path, started: u64, run: &Run, steps: Vec<Value>, failed: usize, stopped: &str) -> i32 {
    let st = run.sh.st.lock().unwrap();
    let doc = json!({
        "tool": "bridgey-accept", "ok": failed == 0 && stopped.is_empty(), "started": started, "finished": now_unix(), "seed": run.opts.seed,
        "target": run.opts.target.to_string(), "peer_platform": run.cfg.platform, "mid": run.opts.mid, "stopped": stopped,
        "expectations_mib": {"cut_loss": mb(CUT_LOSS), "kill_loss": mb(KILL_LOSS)},
        "peer": {"disconnects": st.disconnects, "errors": st.errors, "pairing_prompts": st.pairing_prompts},
        "passed": steps.len() - failed, "failed": failed, "steps": steps,
    });
    drop(st);
    let _ = std::fs::write(path, serde_json::to_string_pretty(&doc).unwrap());
    run.client.stop();
    eprintln!("accept report: {} ({failed} failed)", path.display());
    if doc["ok"] == json!(true) {
        0
    } else {
        1
    }
}
