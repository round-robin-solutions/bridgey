#!/usr/bin/env python3
"""Judges Bridgey's upgrade acceptance and soak runs (docs/acceptance-1.0.md). Standard library only.

  acceptance.py compare --platform android|macos --dir OUT
      Compares the app's state before the upgrade (before.json), right after it (after.json) and after more traffic
      (after-traffic.json), as the stress runners' `snapshot` verb wrote them: settings, trust, per-device grants,
      history, resume records and the version. Writes OUT/compare.json; exits 1 when anything was lost or reset.

  acceptance.py soak --platform android|macos --report soak.json --samples samples.jsonl --out OUT [--crash-log FILE]
      Judges a soak's samples against the thresholds below, writes OUT/soak-summary.json and SVG graphs; exits 1 when a
      threshold fails or the soak report itself failed.
"""

import argparse
import json
import os
import re
import statistics
import sys

MIB_KB = 1024

# Soak thresholds. Windows exclude the first WARMUP_MIN minutes (caches filling, the JIT, the first transfers), or the
# first 15 % of a shorter run.
WARMUP_MIN = 20
THRESHOLDS = {
    # Memory: growth per hour by a least-squares fit, and the last window against the first. Android: resident size.
    # Mac: the physical footprint (Activity Monitor's Memory); resident size there also counts the shared code and the
    # pages malloc keeps after a free, and is only charted.
    "rss_slope_mib_h": {"android": 8.0, "macos": 8.0},
    "rss_growth_mib": {"android": 48.0, "macos": 48.0},
    # Java heap after a collection (Android only).
    "heap_slope_mib_h": 2.0,
    "heap_growth_mib": 12.0,
    # Open files and threads: the last window's median over the first's, and the highest value over the first median.
    "fds_growth": 8,
    "fds_peak_over": 48,
    "threads_growth": 8,
    # Peaks during batches are by design (Kotlin's IO dispatcher alone may grow to 64 threads); runaway growth is not.
    "threads_peak_over": 96,
    # Notifications the Android app shows at once: Android refuses an app's notifications past 50, which would hide
    # pairing, call and control prompts.
    "notifications_max": 20,
    # The driver itself (the session client): resident memory growth per hour, and the last window over the first.
    "peer_rss_slope_mib_h": 16.0,
    "peer_rss_growth_mib": 48.0,
    # Slopes are judged on runs of at least this many hours; shorter runs are mostly warm-up (buffers and caches filling
    # with the first large files), so they are judged on the windows' growth alone.
    "slope_min_hours": 2.0,
    # Idle periods: the app's CPU time as a share of one core, and wakeups. A Mac test instance's control timer (five
    # status files a second) costs about 1.6 % of a core on its own (sampled 27 Nov 2026), hence the Mac's higher bar.
    "idle_cpu_percent": {"android": 2.0, "macos": 3.0},
    "alarm_wakeups_per_hour": 12.0,
    "mac_idle_wakeups_per_s": 20.0,
    # Whole files of at least 16 MiB (smaller ones measure the per-file round trips more than the link): the last
    # window's median speed against the first's, per direction, when each window has at least three.
    "throughput_ratio": 0.5,
    "throughput_min_mib": 16,
}

# Keys whose values may change between two snapshots of the same install without anything being lost or reset.
VOLATILE = {
    "android": [
        r"^bridgey\.reconnect:",          # address book: lastSeen and addresses move with every connection
        r"^bridgey\.updates:last_checked_at$",
        r"^bridgey\.connect:",            # Connect anywhere state (off in the stress build)
        r"^bridgey\.agents",
        r"^bridgey\.health",
    ],
    "macos": [
        r"^reconnect\.addressBook\.v1$",
        r"^NSWindow Frame ",
        r"^NSStatusItem",
        r"^NSSplitView",
        r"^NSTableView",
        r"^NSNavLastRootDirectory",
        r"^SU",                            # Sparkle's own state
        r"^connect\.",
        r"^ConnectTiming",
        r"^diagnostics",
        r"^settings\.receiveFolderBookmark$",  # a bookmark is re-resolved and may be refreshed
    ],
}


# Keys that record the version itself (What's new): they must move to the new build.
FOLLOWS_VERSION = {"android": [r"whats_?new", r"last_version", r"last_build"], "macos": [r"^whatsNew\."]}


def load(path):
    with open(path) as f:
        return json.load(f)


# ---------------------------------------------------------------------------------------------------------------
# Upgrade acceptance


# Fields inside stored JSON that name the process that wrote them, so they change with every start.
PER_PROCESS = {"leaseProcess"}


def per_process_free(value):
    """A stored JSON string without its per-process fields; anything else as it is."""
    if not isinstance(value, str) or not value.startswith("{"):
        return value
    try:
        doc = json.loads(value)
    except ValueError:
        return value
    if not isinstance(doc, dict) or not PER_PROCESS & set(doc):
        return value
    return json.dumps({k: v for k, v in doc.items() if k not in PER_PROCESS}, sort_keys=True)


def flat_prefs(platform, snap):
    """{"file:key" or "key": value} for the preferences a snapshot holds."""
    out = {}
    prefs = snap.get("prefs") or {}
    if platform == "android":
        for name, values in prefs.items():
            for key, entry in values.items():
                out["%s:%s" % (name, key)] = (entry.get("type"), per_process_free(entry.get("value")))
    else:
        for key, value in prefs.items():
            out[key] = per_process_free(value)
    return out


def volatile(platform, key):
    return any(re.search(p, key) for p in VOLATILE[platform])


def item_ids(snap, name):
    entry = (snap.get("files") or {}).get(name) or {}
    return [i.get("id") for i in entry.get("items", []) if isinstance(i, dict) and i.get("id") is not None]


def records(snap):
    entry = (snap.get("files") or {}).get("file-resume.json") or {}
    return entry.get("records", [])


def record_key(r):
    for k in ("offerId", "transferId", "id", "name", "fileName", "sha256"):
        if k in r:
            return "%s=%s" % (k, r[k])
    return json.dumps(r, sort_keys=True)


def compare(platform, before, after, final):
    failures, notes = [], []
    if not (after.get("versionCode", 0) > before.get("versionCode", 0)):
        failures.append("version code went from %s to %s: not an upgrade" % (before.get("versionCode"), after.get("versionCode")))
    if before.get("versionName") == after.get("versionName"):
        failures.append("the version name did not change (%s)" % before.get("versionName"))
    if after.get("pid") is not None and before.get("pid") == after.get("pid"):
        failures.append("the app's process did not restart across the upgrade")

    b, a = flat_prefs(platform, before), flat_prefs(platform, after)
    changed, removed, skipped, followed = [], [], [], []
    new_marks = {str(after.get("versionName")), str(after.get("versionCode"))}
    for key, value in sorted(b.items()):
        follows = any(re.search(p, key, re.I) for p in FOLLOWS_VERSION[platform])
        if key not in a:
            (skipped if volatile(platform, key) else removed).append(key)
        elif a[key] != value and follows:
            now = a[key][1] if platform == "android" and isinstance(a[key], tuple) else a[key]
            if str(now) in new_marks:
                followed.append(key)
            else:
                failures.append("%s moved to %r, not to the new version %s" % (key, now, sorted(new_marks)))
        elif a[key] != value:
            (skipped if volatile(platform, key) else changed).append(key)
    for key in removed:
        failures.append("setting removed by the upgrade: %s (was %r)" % (key, b[key]))
    for key in changed:
        failures.append("setting changed by the upgrade: %s %r -> %r" % (key, b[key], a[key]))
    added = sorted(set(a) - set(b))
    notes.append("%d settings kept, %d moved to the new version (%s), %d volatile keys moved (%s), %d added by the new build" % (
        len(b) - len(removed) - len(changed) - len(skipped) - len(followed), len(followed), ", ".join(followed), len(skipped), ", ".join(skipped[:8]), len(added)))

    # The device's own identity and the devices it trusts.
    if platform == "android":
        if before.get("trusted") != after.get("trusted"):
            failures.append("trusted devices or their switches and grants changed: %s -> %s" % (
                json.dumps(before.get("trusted")), json.dumps(after.get("trusted"))))
        if before.get("unattended") != after.get("unattended"):
            failures.append("Unattended access went from %s to %s" % (before.get("unattended"), after.get("unattended")))
        if before.get("unattended") is not False:
            failures.append("the snapshot before the upgrade does not show Unattended access off (the set-up did not take)")
        grants_b = ((before.get("files") or {}).get("phone-control-grants.json") or {}).get("grants")
        grants_a = ((after.get("files") or {}).get("phone-control-grants.json") or {}).get("grants")
        if grants_b != grants_a:
            failures.append("phone control grants changed: %s -> %s" % (json.dumps(grants_b), json.dumps(grants_a)))
        trusted = before.get("trusted") or []
        if not trusted:
            failures.append("no trusted device before the upgrade")
        for t in trusted:
            if t.get("controlChoice") != "always" or not (t.get("features") or {}).get("screen_draft1"):
                failures.append("the set-up did not take for %s: control %s, screen %s" % (
                    t.get("id", "")[:8], t.get("controlChoice"), (t.get("features") or {}).get("screen_draft1")))
    else:
        tb = (before.get("files") or {}).get("trust-v3.json") or {}
        ta = (after.get("files") or {}).get("trust-v3.json") or {}
        for k in ("version", "devices", "identityKey"):
            if tb.get(k) != ta.get(k):
                failures.append("trust-v3.json %s changed: %r -> %r" % (k, tb.get(k), ta.get(k)))
        if not tb.get("devices"):
            failures.append("no trusted device before the upgrade")
        gb = ((before.get("files") or {}).get("screen-grants-v1.json") or {}).get("doc")
        ga = ((after.get("files") or {}).get("screen-grants-v1.json") or {}).get("doc")
        if gb != ga:
            failures.append("screen grants changed: %s -> %s" % (json.dumps(gb), json.dumps(ga)))
        if not gb or gb.get("unattended") is not False or not any(g.get("mode") == "always" for g in (gb.get("grants") or {}).values()):
            failures.append("the set-up did not take: screen grants before the upgrade were %s" % json.dumps(gb))
        for name, entry in sorted((before.get("files") or {}).items()):
            mode_a = ((after.get("files") or {}).get(name) or {}).get("mode")
            if entry.get("mode") and mode_a and mode_a != entry["mode"]:
                failures.append("%s: permissions went from %s to %s" % (name, entry["mode"], mode_a))
        if not any(k.endswith(".remote_input_draft1") and v is True for k, v in b.items() if k.startswith("settings.device.")):
            failures.append("the set-up did not take: no per-phone Remote control switch before the upgrade")

    # History: every item from before is still there after more traffic.
    names = ["activity-stream.json"] + (["transfer-history.json"] if platform == "macos" else [])
    for name in names:
        ids_b, ids_f = item_ids(before, name), set(item_ids(final, name))
        lost = [i for i in ids_b if i not in ids_f]
        if not ids_b:
            failures.append("%s was empty before the upgrade (the set-up made no history)" % name)
        if lost:
            failures.append("%s: %d of %d items from before the upgrade are gone" % (name, len(lost), len(ids_b)))
        notes.append("%s: %d items before, %d after more traffic" % (name, len(ids_b), len(ids_f)))

    # Resume records: the kept partial's record survives the upgrade; none is left once both files finished.
    rb, ra, rf = records(before), records(after), records(final)
    if not rb:
        failures.append("no resume record before the upgrade (the kept partial left none)")
    keys_a = {record_key(r) for r in ra}
    for r in rb:
        if record_key(r) not in keys_a:
            failures.append("resume record lost in the upgrade: %s" % record_key(r))
    if len(ra) < len(rb) + 1:
        notes.append("after the upgrade: %d resume records (before %d; the file the upgrade cut adds one when the app checkpointed it)" % (len(ra), len(rb)))
    if rf:
        failures.append("%d resume record(s) left after both partials finished: %s" % (len(rf), [record_key(r) for r in rf]))
    return failures, notes


def cmd_compare(args):
    d = args.dir
    out = {"platform": args.platform, "ok": False, "failures": [], "notes": []}
    try:
        before, after, final = (load(os.path.join(d, n)) for n in ("before.json", "after.json", "after-traffic.json"))
    except (OSError, ValueError) as e:
        out["failures"].append("snapshots missing: %s" % e)
    else:
        out["failures"], out["notes"] = compare(args.platform, before, after, final)
        out["versions"] = {"before": [before.get("versionName"), before.get("versionCode")], "after": [after.get("versionName"), after.get("versionCode")]}
    try:
        accept = load(os.path.join(d, "accept.json"))
        out["driver_ok"] = accept.get("ok")
    except (OSError, ValueError):
        out["driver_ok"] = None
    out["ok"] = not out["failures"]
    with open(os.path.join(d, "compare.json"), "w") as f:
        json.dump(out, f, indent=1)
    for line in out["notes"]:
        print("  " + line)
    for line in out["failures"]:
        print("  FAIL " + line)
    print("compare: %s (%s)" % ("ok" if out["ok"] else "FAILED", os.path.join(d, "compare.json")))
    return 0 if out["ok"] else 1


# ---------------------------------------------------------------------------------------------------------------
# Soak


def slope_per_hour(points):
    """Least-squares slope of (seconds, value) points, per hour; None for fewer than three points."""
    if len(points) < 3:
        return None
    xs = [p[0] / 3600.0 for p in points]
    ys = [p[1] for p in points]
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    if den == 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den


def warmup(t_end):
    return min(WARMUP_MIN * 60, 0.15 * t_end)


def windows(points, t_end):
    """The first and last windows after the warm-up: an hour each on long runs, a third of the rest on short ones."""
    start = warmup(t_end)
    span = max(0.0, t_end - start)
    size = 3600.0 if span >= 3 * 3600 else span / 3.0
    first = [v for t, v in points if start <= t < start + size]
    last = [v for t, v in points if t >= t_end - size]
    return first, last


def cpu_seconds(app, platform):
    if platform == "android":
        v = app.get("cpuMs")
        return v / 1000.0 if isinstance(v, (int, float)) else None
    text = app.get("cpu") or ""
    m = re.match(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$", text.strip())
    if not m:
        return None
    days, hours, minutes, seconds = m.groups()
    return int(days or 0) * 86400 + int(hours or 0) * 3600 + int(minutes) * 60 + float(seconds)


def judge_soak(platform, report, samples, crash_log):
    app = [s for s in samples if s.get("kind") == "app" and isinstance(s.get("app"), dict) and s["app"].get("ok", True) and "error" not in s["app"]]
    ops = [s for s in samples if s.get("kind") == "op"]
    t_end = max([s["t"] for s in samples] or [0])
    checks, metrics = [], {}

    def check(name, ok, detail):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})

    check("soak report", report.get("ok") is True, "; ".join(report.get("failures") or []) or "every operation passed, transfers ended done/cancelled/interrupted, no clipboard lost with the link up")
    pids = sorted({s["app"].get("pid") for s in app if s["app"].get("pid") is not None})
    check("no crash", len(pids) <= 1 and not crash_log, "app process ids seen: %s%s" % (pids, "; crash buffer: " + crash_log[:300] if crash_log else ""))
    missing = sum(1 for s in samples if s.get("kind") == "app") - len(app)
    metrics["samples"] = {"app": len(app), "failed": missing, "ops": len(ops), "hours": round(t_end / 3600.0, 2)}

    def series(key, only_gc=False, scale=1.0, source="app"):
        out = []
        for s in app:
            if only_gc and not s.get("gc"):
                continue
            v = (s.get(source) or {}).get(key)
            if isinstance(v, (int, float)) and v >= 0:
                out.append((s["t"], v * scale))
        return out

    after_warmup = lambda pts: [p for p in pts if p[0] >= warmup(t_end)]  # noqa: E731
    long_run = t_end >= THRESHOLDS["slope_min_hours"] * 3600
    judged = lambda slope, limit: slope is None or slope <= limit or not long_run  # noqa: E731

    rss = series("rss_kb", scale=1.0 / MIB_KB)
    footprint = series("footprint_kb", scale=1.0 / MIB_KB) if platform == "macos" else []
    if rss:
        metrics["rss_mib"] = {"start": round(rss[0][1], 1), "end": round(rss[-1][1], 1), "max": round(max(v for _, v in rss), 1),
                              "slope_per_hour": None if slope_per_hour(after_warmup(rss)) is None else round(slope_per_hour(after_warmup(rss)), 2)}
    memory, label, key = (footprint, "physical footprint", "footprint_mib") if footprint else (rss, "resident memory", "rss_mib")
    if memory:
        first, last = windows(memory, t_end)
        slope = slope_per_hour(after_warmup(memory))
        growth = (statistics.median(last) - statistics.median(first)) if first and last else None
        metrics[key] = {"start": round(memory[0][1], 1), "first_median": round(statistics.median(first), 1) if first else None,
                        "last_median": round(statistics.median(last), 1) if last else None, "max": round(max(v for _, v in memory), 1),
                        "slope_per_hour": round(slope, 2) if slope is not None else None, "since_minute": round(memory[0][0] / 60, 1)}
        limit_s, limit_g = THRESHOLDS["rss_slope_mib_h"][platform], THRESHOLDS["rss_growth_mib"][platform]
        check(label, judged(slope, limit_s) and (growth is None or growth <= limit_g),
              "slope %s MiB/h (limit %s%s), last window %s MiB over the first (limit %s)" % (
                  None if slope is None else round(slope, 2), limit_s, "" if long_run else ", not judged under 2 hours",
                  None if growth is None else round(growth, 1), limit_g))
    if platform == "android":
        heap = series("javaUsed", only_gc=True, scale=1.0 / (1024 * 1024))
        if heap:
            first, last = windows(heap, t_end)
            slope = slope_per_hour(after_warmup(heap))
            growth = (statistics.median(last) - statistics.median(first)) if first and last else None
            metrics["java_heap_after_gc_mib"] = {"first_median": round(statistics.median(first), 2) if first else None,
                                                 "last_median": round(statistics.median(last), 2) if last else None,
                                                 "max": round(max(v for _, v in heap), 2), "slope_per_hour": None if slope is None else round(slope, 3)}
            check("Java heap after GC", judged(slope, THRESHOLDS["heap_slope_mib_h"]) and (growth is None or growth <= THRESHOLDS["heap_growth_mib"]),
                  "slope %s MiB/h (limit %s), last window %s MiB over the first (limit %s)" % (
                      None if slope is None else round(slope, 3), THRESHOLDS["heap_slope_mib_h"], None if growth is None else round(growth, 2), THRESHOLDS["heap_growth_mib"]))
    for key, label, growth_limit, peak_limit in (("fds", "open files", "fds_growth", "fds_peak_over"), ("threads", "threads", "threads_growth", "threads_peak_over")):
        pts = series(key)
        if not pts:
            check(label, False, "no samples")
            continue
        first, last = windows(pts, t_end)
        if not first or not last:
            continue
        base = statistics.median(first)
        growth = statistics.median(last) - base
        peak = max(v for t, v in pts if t >= warmup(t_end)) - base
        metrics[key] = {"first_median": base, "last_median": statistics.median(last), "max": max(v for _, v in pts), "slope_per_hour": round(slope_per_hour(after_warmup(pts)) or 0, 2)}
        check(label, growth <= THRESHOLDS[growth_limit] and peak <= THRESHOLDS[peak_limit],
              "last window median %+g over the first (limit %s), peak %+g (limit %s)" % (growth, THRESHOLDS[growth_limit], peak, THRESHOLDS[peak_limit]))
    peer = series("rss_kb", scale=1.0 / MIB_KB, source="peer")
    if peer:
        slope = slope_per_hour(after_warmup(peer))
        first, last = windows(peer, t_end)
        growth = (statistics.median(last) - statistics.median(first)) if first and last else None
        metrics["peer_rss_mib"] = {"start": round(peer[0][1], 1), "end": round(peer[-1][1], 1), "slope_per_hour": None if slope is None else round(slope, 2)}
        check("driver memory (session client)", judged(slope, THRESHOLDS["peer_rss_slope_mib_h"]) and (growth is None or growth <= THRESHOLDS["peer_rss_growth_mib"]),
              "slope %s MiB/h (limit %s%s), last window %s MiB over the first (limit %s)" % (
                  None if slope is None else round(slope, 2), THRESHOLDS["peer_rss_slope_mib_h"], "" if long_run else ", not judged under 2 hours",
                  None if growth is None else round(growth, 1), THRESHOLDS["peer_rss_growth_mib"]))

    # Idle periods: consecutive samples both inside one idle period.
    idle_cpu, idle_seconds, idle_wake = 0.0, 0.0, 0.0
    for prev, cur in zip(app, app[1:]):
        if not (prev.get("idle") and cur.get("idle")):
            continue
        dt = cur["t"] - prev["t"]
        c0, c1 = cpu_seconds(prev["app"], platform), cpu_seconds(cur["app"], platform)
        if dt <= 0 or c0 is None or c1 is None or c1 < c0:
            continue
        idle_seconds += dt
        idle_cpu += c1 - c0
        if platform == "macos":
            w0, w1 = prev["app"].get("idle_wakeups"), cur["app"].get("idle_wakeups")
            if isinstance(w0, (int, float)) and isinstance(w1, (int, float)) and w1 >= w0:
                idle_wake += w1 - w0
    if idle_seconds > 0:
        pct = 100.0 * idle_cpu / idle_seconds
        metrics["idle"] = {"seconds": round(idle_seconds), "cpu_percent": round(pct, 3)}
        check("CPU while idle", pct <= THRESHOLDS["idle_cpu_percent"][platform], "%.3f%% of one core over %d idle seconds (limit %s%%)" % (pct, idle_seconds, THRESHOLDS["idle_cpu_percent"][platform]))
        if platform == "macos":
            rate = idle_wake / idle_seconds
            metrics["idle"]["wakeups_per_s"] = round(rate, 2)
            check("wakeups while idle", rate <= THRESHOLDS["mac_idle_wakeups_per_s"], "%.2f idle wakeups a second (limit %s)" % (rate, THRESHOLDS["mac_idle_wakeups_per_s"]))
    else:
        check("CPU while idle", False, "no idle period with two samples")
    if platform == "android":
        alarms = series("alarm_wakeups")
        if len(alarms) >= 2:
            per_hour = (alarms[-1][1] - alarms[0][1]) / max(1e-9, (alarms[-1][0] - alarms[0][0]) / 3600.0)
            metrics["alarm_wakeups"] = {"start": alarms[0][1], "end": alarms[-1][1], "per_hour": round(per_hour, 2)}
            check("alarm wakeups", per_hour <= THRESHOLDS["alarm_wakeups_per_hour"], "%.2f an hour (limit %s)" % (per_hour, THRESHOLDS["alarm_wakeups_per_hour"]))
        else:
            metrics["alarm_wakeups"] = {"note": "the system listed no wakeup alarms for the app"}
            check("alarm wakeups", True, "none listed for the app")
        shown = series("notifications")
        if shown:
            peak = max(v for _, v in shown)
            metrics["notifications"] = {"max": peak, "last": shown[-1][1]}
            check("notifications shown", peak <= THRESHOLDS["notifications_max"], "at most %d at once (limit %d; Android refuses past 50)" % (peak, THRESHOLDS["notifications_max"]))
        locks = series("wakelocks")
        if locks:
            metrics["wakelocks_held"] = {"max": max(v for _, v in locks), "idle_max": max([s["app"].get("wakelocks", 0) for s in app if s.get("idle")] or [0])}

    # Throughput over time, per direction.
    speeds = {"send-whole": [], "recv-whole": []}
    for op in ops:
        if op.get("op") in speeds:
            for r in op.get("rounds") or []:
                if r.get("done") and (r.get("size") or 0) >= THRESHOLDS["throughput_min_mib"] << 20 and r.get("mib_per_s"):
                    speeds[op["op"]].append((op["t"], r["mib_per_s"]))
    metrics["throughput_mib_s"] = {}
    for name, pts in speeds.items():
        if not pts:
            continue
        first, last = windows(pts, t_end)
        if len(first) < 3 or len(last) < 3:
            metrics["throughput_mib_s"][name] = {"n": len(pts), "note": "fewer than three large files in a window", "median": round(statistics.median(v for _, v in pts), 1)}
            continue
        ratio = statistics.median(last) / max(1e-9, statistics.median(first))
        metrics["throughput_mib_s"][name] = {"n": len(pts), "first_median": round(statistics.median(first), 1), "last_median": round(statistics.median(last), 1),
                                             "min": round(min(v for _, v in pts), 1), "max": round(max(v for _, v in pts), 1), "ratio": round(ratio, 2)}
        check("throughput %s" % name, ratio >= THRESHOLDS["throughput_ratio"], "last window median %.1f MiB/s against %.1f first (ratio %.2f, limit %s)" % (
            statistics.median(last), statistics.median(first), ratio, THRESHOLDS["throughput_ratio"]))
    metrics["operations"] = {}
    for op in ops:
        m = metrics["operations"].setdefault(op.get("op"), {"n": 0, "failed": 0})
        m["n"] += 1
        m["failed"] += 0 if op.get("ok") else 1
    return checks, metrics, {"rss": rss, "footprint": footprint, "peer": peer, "ops": ops, "app": app}


# ---------------------------------------------------------------------------------------------------------------
# Graphs: static SVG line charts (one measure per chart, one axis each), idle periods shaded.

SURFACE, INK, INK2, GRID, IDLE = "#ffffff", "#191919", "#666666", "#e6e6e6", "#f2f2f2"
SERIES = ["#257de0", "#f47230", "#00b894", "#6a4ce2"]


def svg_chart(path, title, unit, lines, idle_spans, t_end, points=False):
    """lines: [(label, [(seconds, value)])]. Writes a 760x300 SVG."""
    w, h, left, right, top, bottom = 760, 300, 64, 150, 40, 40
    pw, ph = w - left - right, h - top - bottom
    values = [v for _, pts in lines for _, v in pts]
    if not values:
        return False
    lo, hi = min(0.0, min(values)), max(values)
    if hi <= lo:
        hi = lo + 1
    hi *= 1.08
    hours = max(t_end / 3600.0, 1e-6)
    x = lambda t: left + pw * (t / 3600.0) / hours  # noqa: E731
    y = lambda v: top + ph - ph * (v - lo) / (hi - lo)  # noqa: E731
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="-apple-system, Helvetica, Arial, sans-serif">' % (w, h, w, h),
           '<rect width="100%%" height="100%%" fill="%s"/>' % SURFACE,
           '<text x="%d" y="24" font-size="15" font-weight="600" fill="%s">%s</text>' % (left, INK, title)]
    for a, b in idle_spans:
        out.append('<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="%s"><title>idle</title></rect>' % (x(a), top, max(1.0, x(b) - x(a)), ph, IDLE))
    for i in range(5):
        v = lo + (hi - lo) * i / 4
        out.append('<line x1="%d" x2="%d" y1="%.1f" y2="%.1f" stroke="%s" stroke-width="1"/>' % (left, left + pw, y(v), y(v), GRID))
        out.append('<text x="%d" y="%.1f" font-size="11" fill="%s" text-anchor="end">%s</text>' % (left - 6, y(v) + 4, INK2, ("%.0f" % v) if hi - lo >= 10 else ("%.2f" % v)))
    step = 1 if hours <= 8 else 2
    hr = 0
    while hr <= hours + 1e-9:
        out.append('<text x="%.1f" y="%d" font-size="11" fill="%s" text-anchor="middle">%dh</text>' % (x(hr * 3600), top + ph + 16, INK2, hr))
        hr += step
    out.append('<text x="%d" y="%d" font-size="11" fill="%s">%s</text>' % (left, top + ph + 32, INK2, unit))
    for i, (label, pts) in enumerate(lines):
        color = SERIES[i % len(SERIES)]
        pts = sorted(pts)
        if points:
            for t, v in pts:
                out.append('<circle cx="%.1f" cy="%.1f" r="3" fill="%s"><title>%s %.1fh: %.1f</title></circle>' % (x(t), y(v), color, label, t / 3600.0, v))
        else:
            d = " ".join(("M" if j == 0 else "L") + "%.1f %.1f" % (x(t), y(v)) for j, (t, v) in enumerate(pts))
            out.append('<path d="%s" fill="none" stroke="%s" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>' % (d, color))
            for t, v in pts[:: max(1, len(pts) // 60)]:
                out.append('<circle cx="%.1f" cy="%.1f" r="6" fill="transparent"><title>%s %.1fh: %.2f</title></circle>' % (x(t), y(v), label, t / 3600.0, v))
        ly = top + 14 + 18 * i
        out.append('<rect x="%d" y="%d" width="14" height="3" rx="1.5" fill="%s"/>' % (left + pw + 16, ly - 4, color))
        out.append('<text x="%d" y="%d" font-size="12" fill="%s">%s</text>' % (left + pw + 36, ly, INK, label))
    if idle_spans:
        ly = top + 14 + 18 * len(lines)
        out.append('<rect x="%d" y="%d" width="14" height="10" fill="%s" stroke="%s"/>' % (left + pw + 16, ly - 9, IDLE, GRID))
        out.append('<text x="%d" y="%d" font-size="12" fill="%s">idle period</text>' % (left + pw + 36, ly, INK))
    out.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(out))
    return True


def idle_spans(app):
    spans, start = [], None
    for s in app:
        if s.get("idle") and start is None:
            start = s["t"]
        elif not s.get("idle") and start is not None:
            spans.append((start, s["t"]))
            start = None
    if start is not None and app:
        spans.append((start, app[-1]["t"]))
    return spans


def cmd_soak(args):
    report = load(args.report) if os.path.exists(args.report) else {"ok": False, "failures": ["no soak report"]}
    samples = []
    if os.path.exists(args.samples):
        with open(args.samples) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        samples.append(json.loads(line))
                    except ValueError:
                        pass
    crash = ""
    if args.crash_log and os.path.exists(args.crash_log):
        with open(args.crash_log, errors="replace") as f:
            crash = f.read().strip()
        # The crash buffer names every app; only this app's crashes count.
        crash = "\n".join(l for l in crash.splitlines() if "bridgey" in l.lower())
    checks, metrics, data = judge_soak(args.platform, report, samples, crash)
    os.makedirs(args.out, exist_ok=True)
    t_end = max([s["t"] for s in samples] or [1])
    spans = idle_spans(data["app"])
    graphs = []

    def chart(name, *a, **k):
        if svg_chart(os.path.join(args.out, name), *a, **k):
            graphs.append(name)

    app = data["app"]
    pick = lambda key, scale=1.0, gc=False: [(s["t"], s["app"][key] * scale) for s in app if isinstance(s["app"].get(key), (int, float)) and s["app"][key] >= 0 and (s.get("gc") or not gc)]  # noqa: E731
    lines = [("app RSS", data["rss"])] + ([("app footprint", data["footprint"])] if data["footprint"] else []) + [("driver RSS", data["peer"])]
    chart("rss.svg", "App memory", "MiB, by hours into the soak", lines, spans, t_end)
    if args.platform == "android":
        chart("java-heap.svg", "Java heap after GC", "MiB, by hours into the soak", [("Java heap", pick("javaUsed", 1.0 / (1024 * 1024), gc=True))], spans, t_end)
    chart("fds.svg", "Open files", "file descriptors, by hours into the soak", [("app", pick("fds"))], spans, t_end)
    chart("threads.svg", "Threads", "threads, by hours into the soak", [("app", pick("threads"))], spans, t_end)
    speeds = []
    for name in ("send-whole", "recv-whole"):
        pts = [(op["t"], r["mib_per_s"]) for op in data["ops"] if op.get("op") == name for r in op.get("rounds") or [] if r.get("done") and (r.get("size") or 0) >= THRESHOLDS["throughput_min_mib"] << 20 and r.get("mib_per_s")]
        speeds.append(({"send-whole": "to the app", "recv-whole": "from the app"}[name], pts))
    chart("throughput.svg", "Whole-file transfer speed (files of 16 MiB or more)", "MiB/s, by hours into the soak", speeds, spans, t_end, points=True)
    if args.platform == "android":
        chart("alarm-wakeups.svg", "Alarm wakeups for the app since boot", "count, by hours into the soak", [("wakeups", pick("alarm_wakeups"))], spans, t_end)
    else:
        chart("idle-wakeups.svg", "Idle wakeups (cumulative)", "count, by hours into the soak", [("app", pick("idle_wakeups"))], spans, t_end)

    summary = {"platform": args.platform, "ok": all(c["ok"] for c in checks), "thresholds": THRESHOLDS, "warmup_minutes": WARMUP_MIN,
               "checks": checks, "metrics": metrics, "graphs": graphs,
               "report": {k: report.get(k) for k in ("ok", "minutes_planned", "minutes_run", "operations", "clipboard", "transfers", "peer", "failures")}}
    with open(os.path.join(args.out, "soak-summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    for c in checks:
        print("  %s %s: %s" % ("ok  " if c["ok"] else "FAIL", c["check"], c["detail"]))
    print("soak: %s (%s)" % ("ok" if summary["ok"] else "FAILED", os.path.join(args.out, "soak-summary.json")))
    return 0 if summary["ok"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("--platform", choices=["android", "macos"], required=True)
    c.add_argument("--dir", required=True)
    s = sub.add_parser("soak")
    s.add_argument("--platform", choices=["android", "macos"], required=True)
    s.add_argument("--report", required=True)
    s.add_argument("--samples", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--crash-log")
    args = parser.parse_args()
    return cmd_compare(args) if args.cmd == "compare" else cmd_soak(args)


if __name__ == "__main__":
    sys.exit(main())
