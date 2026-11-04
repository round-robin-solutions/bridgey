//! `bridgey`: the agent command for Bridgey by Round Robin (docs/agent-cli.md, setup in docs/agent-cli-setup.md).
//!
//! Each install is its own paired device. The phone grants it nothing until Rahul turns permissions on, and
//! enforces every grant itself.

mod audit;
mod client;
mod config;
mod crypto;
mod daemon;
mod detect;
mod doctor;
mod errors;
mod invite;
mod ipc;
mod ops;
mod paths;
mod service;
mod session;
mod store;
mod time;
mod wire;

use clap::{Args, Parser, Subcommand};
use errors::CliError;
use paths::Paths;
use serde_json::{json, Map, Value};
use std::io::{IsTerminal, Read, Write};
use time::{now_ms, parse_duration};

#[derive(Parser)]
#[command(name = "bridgey", version, about = "Reach your phone from any server: notify, ask, ring, read codes, send files. Bridgey by Round Robin.", disable_help_subcommand = true)]
struct Cli {
    #[command(flatten)]
    global: Global,
    #[command(subcommand)]
    command: Command,
}

#[derive(Args, Clone)]
struct Global {
    /// The paired device to use (name or ID); the only paired device by default
    #[arg(short = 'd', long, global = true, env = "BRIDGEY_DEVICE")]
    device: Option<String>,
    /// A separate install with its own pairing and grants
    #[arg(long, global = true, env = "BRIDGEY_PROFILE")]
    profile: Option<String>,
    /// Print exactly one JSON object
    #[arg(long, global = true)]
    json: bool,
    /// Stream one JSON event per line, ending with the result
    #[arg(long, global = true)]
    jsonl: bool,
    /// How long to wait for a route to the device
    #[arg(long, global = true, value_name = "DURATION")]
    connect_timeout: Option<String>,
}

#[derive(Subcommand)]
enum Command {
    /// Pair with a phone by QR code or link (the code is confirmed on both ends)
    Pair {
        /// The name the phone shows for this install (saved as device_name)
        #[arg(long)]
        name: Option<String>,
        /// Print only the link
        #[arg(long)]
        link_only: bool,
        /// Test hook: answer another install's invite instead of making one
        #[arg(long, hide = true, value_name = "LINK")]
        join: Option<String>,
    },
    /// Paired devices, online state, route and grants
    Devices,
    /// Route, round trip, relay and battery for a device
    Status { device: Option<String> },
    /// What the phone lets this install do, with expiry times
    Grants {
        device: Option<String>,
        #[command(subcommand)]
        action: Option<GrantsAction>,
    },
    /// Send files to the phone (Download/Bridgey/<this device>)
    Send {
        #[arg(required = true)]
        paths: Vec<String>,
        #[arg(long)]
        no_wait: bool,
    },
    /// Current and recent transfers
    Transfers,
    /// Set or request the phone's clipboard
    Clip {
        #[command(subcommand)]
        action: ClipAction,
    },
    /// Post a notification in "Agent messages"
    Notify {
        title: String,
        body: Option<String>,
        #[arg(long, default_value = "normal", value_parser = ["normal", "high"])]
        priority: String,
        /// Replaces this install's earlier notification with the same tag
        #[arg(long)]
        tag: Option<String>,
        /// Shown on the phone as "Says it is from ..."
        #[arg(long)]
        from: Option<String>,
    },
    /// Ask a question with answer buttons and wait for the answer
    Ask(AskArgs),
    /// Wait for (or fetch) the answer to an earlier ask
    Wait {
        ask_id: String,
        #[arg(long, default_value = "30m")]
        timeout: String,
    },
    /// Ring the phone (Find Device)
    Ring {
        #[arg(long, default_value = "30s")]
        duration: String,
        #[arg(long)]
        stop: bool,
    },
    /// Battery level and charging state
    Battery,
    /// One short sound on the phone; reports delivery
    Ping,
    /// One-time codes your Mac (or a server with Detect codes) found in the phone's messages and mail, newest first
    Codes {
        #[command(subcommand)]
        action: Option<CodesAction>,
        /// Only the newest code
        #[arg(long)]
        latest: bool,
        /// Only codes from this service or sender
        #[arg(long)]
        service: Option<String>,
        /// Block until a new code arrives (at most this long)
        #[arg(long, value_name = "DURATION")]
        wait: Option<String>,
        /// How far back to look (default 10m, at most 1h)
        #[arg(long, value_name = "DURATION", default_value = "10m")]
        since: String,
    },
    /// This install's audit log
    Audit {
        #[arg(long, value_name = "DURATION", default_value = "7d")]
        since: String,
    },
    /// Check this host: files, daemon, service, control service, relays, routes, clock, grants
    Doctor,
    /// Remove a pairing on this side
    Forget { device: String },
    /// Read or change config.toml
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },
    /// Install, remove or check the background service (systemd user unit or launchd agent)
    Service {
        #[command(subcommand)]
        action: ServiceAction,
    },
    /// Run the background agent in the foreground (the service runs this)
    Daemon {
        /// Never exit on idle (set by the service files)
        #[arg(long)]
        service: bool,
        /// Ask a running background agent to stop (a service restarts it)
        #[arg(long)]
        stop: bool,
    },
}

#[derive(Subcommand)]
enum GrantsAction {
    /// Ask the phone for grants; they show as "Waiting for you" there
    Request {
        #[arg(required = true)]
        keys: Vec<String>,
        #[arg(long)]
        note: Option<String>,
    },
}

#[derive(Subcommand)]
enum CodesAction {
    /// The code model this install needs to Detect codes for the phone
    Model {
        #[command(subcommand)]
        action: ModelAction,
    },
}

#[derive(Subcommand)]
enum ModelAction {
    /// Whether this build can detect codes and which model is installed
    Status,
    /// Download the model the Mac uses (253 MB, SHA-256 checked) after accepting its terms
    Download {
        /// Accept the Gemma Terms of Use and Prohibited Use Policy (the links are printed without this)
        #[arg(long)]
        accept_terms: bool,
    },
    /// Remove the model; Detect codes stops at once
    Remove,
}

#[derive(Subcommand)]
enum ClipAction {
    /// Put text on the phone's clipboard (- or nothing reads stdin)
    Set {
        text: Option<String>,
        #[arg(long, value_name = "FILE")]
        html: Option<String>,
    },
    /// Ask the phone for its clipboard; Rahul taps Send
    Get {
        #[arg(long, default_value = "2m")]
        timeout: String,
    },
}

#[derive(Subcommand)]
enum ConfigAction {
    Get { key: String },
    Set { key: String, value: String },
    List,
}

#[derive(Subcommand)]
enum ServiceAction {
    Install,
    Uninstall,
    Status,
}

#[derive(Args)]
struct AskArgs {
    title: String,
    body: Option<String>,
    /// An answer button, ID=LABEL (1 to 3)
    #[arg(short = 'o', long = "option", value_name = "ID=LABEL")]
    options: Vec<String>,
    /// Allow a typed answer
    #[arg(long)]
    text: bool,
    #[arg(long)]
    text_hint: Option<String>,
    #[arg(long, default_value = "30m")]
    timeout: String,
    /// The answer buttons need the phone unlocked
    #[arg(long)]
    require_unlock: bool,
    /// Exit 7 unless the answer is this option
    #[arg(long, value_name = "ID")]
    fail_unless: Option<String>,
    /// Print the ask ID once posted and exit; collect the answer with bridgey wait
    #[arg(long)]
    no_wait: bool,
    /// Leave the question on the phone after a timeout
    #[arg(long)]
    keep_on_timeout: bool,
    #[arg(long)]
    from: Option<String>,
}

struct Ctx {
    paths: Paths,
    config: config::Config,
    json: bool,
    jsonl: bool,
    command: String,
    device: Option<String>,
    connect_ms: Option<u64>,
}

impl Ctx {
    fn args(&self, mut extra: Value) -> Value {
        if let Some(d) = &self.device {
            extra["device"] = json!(d);
        }
        if let Some(ms) = self.connect_ms {
            extra["connectTimeoutMs"] = json!(ms);
        }
        extra
    }

    async fn call(&self, cmd: &str, args: Value) -> Result<Value, CliError> {
        let jsonl = self.jsonl;
        let json = self.json;
        client::request(&self.paths, cmd, self.args(args), true, |e| {
            if jsonl {
                println!("{e}");
            } else if !json {
                if let Some(m) = e["message"].as_str().filter(|_| e["event"] == "warning") {
                    eprintln!("bridgey: {m}");
                }
            }
        })
        .await
    }
}

fn usage(msg: impl Into<String>) -> CliError {
    CliError::new("usage", msg)
}

fn ms(text: &str) -> Result<u64, CliError> {
    parse_duration(text).map(|d| d.as_millis() as u64).map_err(usage)
}

fn main() {
    let cli = match Cli::try_parse() {
        Ok(c) => c,
        Err(e) => {
            let code = if e.use_stderr() { 2 } else { 0 };
            let _ = e.print();
            std::process::exit(code);
        }
    };
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("runtime");
    let code = runtime.block_on(run(cli));
    runtime.shutdown_timeout(std::time::Duration::from_millis(500));
    std::process::exit(code);
}

async fn run(cli: Cli) -> i32 {
    let paths = match Paths::resolve(cli.global.profile.as_deref()) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("bridgey: {e}");
            return 2;
        }
    };
    if let Command::Daemon { stop: true, .. } = cli.command {
        return match client::request(&paths, "shutdown", json!({}), false, |_| {}).await {
            Ok(_) => 0,
            Err(e) => {
                eprintln!("bridgey: {}", e.message);
                1
            }
        };
    }
    if let Command::Daemon { service, .. } = cli.command {
        return match daemon::Daemon::run(paths, service).await {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("bridgey daemon: {e}");
                1
            }
        };
    }
    let config = match config::Config::load(&paths) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("bridgey: {e}");
            return 1;
        }
    };
    let json = cli.global.json || std::env::var("BRIDGEY_OUTPUT").is_ok_and(|v| v == "json") || (config.json_output() && !cli.global.jsonl);
    let command = command_name(&cli.command).to_string();
    let connect_ms = match cli.global.connect_timeout.as_deref().map(ms).transpose() {
        Ok(v) => v,
        Err(e) => return finish(&command, json, cli.global.jsonl, Err(e)),
    };
    let device = match &cli.command {
        Command::Status { device: Some(d) } | Command::Grants { device: Some(d), .. } | Command::Forget { device: d } => Some(d.clone()),
        _ => cli.global.device.clone(),
    };
    let ctx = Ctx { paths, config, json, jsonl: cli.global.jsonl, command: command.clone(), device, connect_ms };
    let result = execute(&ctx, cli.command).await;
    finish(&ctx.command, ctx.json, ctx.jsonl, result)
}

fn command_name(c: &Command) -> &'static str {
    match c {
        Command::Pair { .. } => "pair",
        Command::Devices => "devices",
        Command::Status { .. } => "status",
        Command::Grants { action: Some(_), .. } => "grants request",
        Command::Grants { .. } => "grants",
        Command::Send { .. } => "send",
        Command::Transfers => "transfers",
        Command::Clip { action: ClipAction::Set { .. } } => "clip set",
        Command::Clip { action: ClipAction::Get { .. } } => "clip get",
        Command::Notify { .. } => "notify",
        Command::Ask(_) => "ask",
        Command::Wait { .. } => "wait",
        Command::Ring { .. } => "ring",
        Command::Battery => "battery",
        Command::Ping => "ping",
        Command::Codes { action: Some(CodesAction::Model { action: ModelAction::Status }), .. } => "codes model status",
        Command::Codes { action: Some(CodesAction::Model { action: ModelAction::Download { .. } }), .. } => "codes model download",
        Command::Codes { action: Some(CodesAction::Model { action: ModelAction::Remove }), .. } => "codes model remove",
        Command::Codes { .. } => "codes",
        Command::Audit { .. } => "audit",
        Command::Doctor => "doctor",
        Command::Forget { .. } => "forget",
        Command::Config { .. } => "config",
        Command::Service { .. } => "service",
        Command::Daemon { .. } => "daemon",
    }
}

/// Prints the result (text for people, one JSON object, or the closing JSONL line) and returns the exit code.
fn finish(command: &str, json: bool, jsonl: bool, result: Result<(Value, String), CliError>) -> i32 {
    match result {
        Ok((v, text)) => {
            if json || jsonl {
                let mut o = Map::new();
                if jsonl {
                    o.insert("event".into(), json!("result"));
                }
                o.insert("ok".into(), json!(true));
                o.insert("command".into(), json!(command));
                if let Value::Object(m) = &v {
                    for (k, x) in m {
                        if k != "exit" {
                            o.insert(k.clone(), x.clone());
                        }
                    }
                }
                println!("{}", Value::Object(o));
            } else if !text.is_empty() {
                print!("{text}");
                if !text.ends_with('\n') {
                    println!();
                }
            }
            v["exit"].as_i64().map(|e| e as i32).unwrap_or(0)
        }
        Err(e) => {
            if json || jsonl {
                let mut o = json!({"ok": false, "command": command, "error": e.to_json()});
                if jsonl {
                    o["event"] = json!("result");
                }
                println!("{o}");
            } else {
                eprintln!("bridgey {command}: {}", e.message);
            }
            e.exit
        }
    }
}

fn state_text(g: &Value, now: u64) -> String {
    match g["state"].as_str().unwrap_or("off") {
        "on" => match g["expiresAt"].as_u64() {
            Some(t) => {
                let window = match g["window"].as_str() {
                    Some("1h") => " (for 1 hour)",
                    Some("today") => " (today)",
                    Some("7d") => " (7 days)",
                    _ => "",
                };
                format!("On until {}{window}", time::short(t, now))
            }
            None => "On until you turn it off".into(),
        },
        "waiting" => "Waiting for you".into(),
        _ => "Off".into(),
    }
}

fn route_text(route: &Value, relay: &Value) -> String {
    match route.as_str() {
        Some("relay") => format!("relay ({})", relay.as_str().map(daemon::relay_name).unwrap_or_else(|| "?".into())),
        Some("vpn") => "private network".into(),
        Some("lan") => "same network".into(),
        Some("direct") => "direct".into(),
        _ => "-".into(),
    }
}

async fn execute(ctx: &Ctx, command: Command) -> Result<(Value, String), CliError> {
    let now = now_ms();
    match command {
        Command::Daemon { .. } => unreachable!(),
        Command::Pair { name, link_only, join } => pair(ctx, name, link_only, join).await,
        Command::Devices => {
            let v = ctx.call("devices", json!({})).await?;
            let mut t = String::new();
            let list = v["devices"].as_array().cloned().unwrap_or_default();
            if list.is_empty() {
                t.push_str("Nothing paired yet. Run bridgey pair.\n");
            }
            for d in list {
                let state = if d["online"] == true { format!("online, {}, {} ms", route_text(&d["route"], &d["relay"]), d["rttMs"]) } else { format!("away, last seen {}", time::relative(d["lastSeenAt"].as_u64().unwrap_or(0), now)) };
                let granted: Vec<String> = d["granted"].as_array().map(|a| a.iter().filter_map(|g| g.as_str().map(str::to_string)).collect()).unwrap_or_default();
                t.push_str(&format!("{}  ({})\n  {}\n  granted: {}\n", d["name"].as_str().unwrap_or("?"), daemon::short(d["id"].as_str().unwrap_or("")), state, if granted.is_empty() { "nothing yet".into() } else { granted.join(", ") }));
            }
            Ok((v, t))
        }
        Command::Status { .. } => {
            let v = ctx.call("device-status", json!({})).await?;
            let mut t = format!("{}: {}, round trip {} ms (connected in {} ms)\n", v["device"]["name"].as_str().unwrap_or("?"), route_text(&v["route"], &v["relay"]), v["rttMs"], v["connectMs"]);
            if let Some(b) = v["battery"].as_object() {
                t.push_str(&format!("Battery {}%{}\n", b["level"], if b["charging"] == true { ", charging" } else { "" }));
            }
            Ok((v, t))
        }
        Command::Grants { action: Some(GrantsAction::Request { keys, note }), .. } => {
            let v = ctx.call("grants-request", json!({"keys": keys, "note": note})).await?;
            let t = format!("Asked {} for: {}. They show as \"Waiting for you\" on the phone.\n", v["device"]["name"].as_str().unwrap_or("the phone"), keys.iter().map(|k| daemon::grant_title(k)).collect::<Vec<_>>().join(", "));
            Ok((v, t))
        }
        Command::Grants { action: None, .. } => {
            let v = ctx.call("grants", json!({})).await?;
            let mut t = format!(
                "What {} lets this device do{}\n\n",
                v["device"]["name"].as_str().unwrap_or("the phone"),
                if v["live"] == true { String::new() } else { format!(" (phone away; as of {})", v["asOf"].as_u64().map(|a| time::relative(a, now)).unwrap_or_else(|| "never".into())) }
            );
            for g in v["grants"].as_array().cloned().unwrap_or_default() {
                let mut line = format!("  {:<24} {}", g["title"].as_str().unwrap_or(""), state_text(&g, now));
                if let Some(at) = g["grantedAt"].as_u64().filter(|_| g["state"] == "on") {
                    line.push_str(&format!(", granted {}", time::relative(at, now)));
                }
                t.push_str(&line);
                t.push('\n');
                t.push_str(&format!("  {:<24} {}\n", "", g["detail"].as_str().unwrap_or("")));
            }
            t.push_str("\nChange these in Bridgey on the phone: Devices, this device, Permissions.\n");
            Ok((v, t))
        }
        Command::Send { paths, no_wait } => {
            let abs: Vec<String> = paths.iter().map(|p| std::fs::canonicalize(p).map(|a| a.display().to_string()).unwrap_or_else(|_| p.clone())).collect();
            let v = ctx.call("send", json!({"paths": abs, "noWait": no_wait})).await?;
            let t = format!("Sent {} file(s), {} bytes, to {}\n", v["files"], v["bytes"], v["device"]["name"].as_str().unwrap_or("the phone"));
            Ok((v, t))
        }
        Command::Transfers => {
            let v = ctx.call("transfers", json!({})).await?;
            let mut t = String::new();
            for x in v["transfers"].as_array().cloned().unwrap_or_default() {
                t.push_str(&format!("{}  {}  {}/{} bytes  {}  {}\n", daemon::short(x["transferId"].as_str().unwrap_or("")), x["name"].as_str().unwrap_or(""), x["bytes"], x["total"], x["state"].as_str().unwrap_or(""), time::relative(x["startedAt"].as_u64().unwrap_or(0), now)));
            }
            if t.is_empty() {
                t = "No transfers since the background agent started.\n".into();
            }
            Ok((v, t))
        }
        Command::Clip { action: ClipAction::Set { text, html } } => {
            let text = match text.as_deref() {
                Some("-") | None => {
                    if text.is_none() && std::io::stdin().is_terminal() {
                        return Err(usage("bridgey clip set TEXT (or - to read stdin)"));
                    }
                    let mut s = String::new();
                    std::io::stdin().read_to_string(&mut s).map_err(|e| usage(e.to_string()))?;
                    s
                }
                Some(t) => t.to_string(),
            };
            let html = html.map(|f| std::fs::read_to_string(&f).map_err(|e| usage(format!("{f}: {e}")))).transpose()?;
            let v = ctx.call("clip-set", json!({"text": text, "html": html})).await?;
            Ok((v.clone(), format!("Copied to {}\n", v["device"]["name"].as_str().unwrap_or("the phone"))))
        }
        Command::Clip { action: ClipAction::Get { timeout } } => {
            let v = ctx.call("clip-get", json!({"timeoutMs": ms(&timeout)?})).await?;
            let text = v["text"].as_str().unwrap_or("").to_string();
            Ok((v, text))
        }
        Command::Notify { title, body, priority, tag, from } => {
            check_len("title", &title, 1, 120)?;
            if let Some(b) = &body {
                check_len("body", b, 0, 1000)?;
            }
            let v = ctx.call("notify", json!({"title": title, "body": body, "priority": priority, "tag": tag, "from": from})).await?;
            Ok((v.clone(), format!("Posted on {}\n", v["device"]["name"].as_str().unwrap_or("the phone"))))
        }
        Command::Ask(a) => ask(ctx, a).await,
        Command::Wait { ask_id, timeout } => {
            let v = ctx.call("wait", json!({"askId": ask_id, "timeoutMs": ms(&timeout)?})).await?;
            let t = answer_text(&v);
            Ok((v, t))
        }
        Command::Ring { duration, stop } => {
            let v = ctx.call("ring", json!({"durationMs": ms(&duration)?, "stop": stop})).await?;
            let t = if stop { "Stopped ringing\n".to_string() } else { format!("Ringing {} for {} s\n", v["device"]["name"].as_str().unwrap_or("the phone"), v["durationMs"].as_u64().unwrap_or(0) / 1000) };
            Ok((v, t))
        }
        Command::Battery => {
            let v = ctx.call("battery", json!({})).await?;
            let t = format!("{}%{}\n", v["level"], if v["charging"] == true { ", charging" } else { "" });
            Ok((v, t))
        }
        Command::Ping => {
            let v = ctx.call("ping", json!({})).await?;
            Ok((v.clone(), format!("Delivered to {} in {} ms\n", v["device"]["name"].as_str().unwrap_or("the phone"), v["rttMs"])))
        }
        Command::Codes { action: Some(CodesAction::Model { action }), .. } => {
            let v = match action {
                ModelAction::Status => detect::status(&ctx.paths),
                ModelAction::Download { accept_terms } => {
                    let paths = ctx.paths.clone();
                    let record = tokio::task::spawn_blocking(move || detect::download(&paths, accept_terms)).await.map_err(|e| CliError::new("failed", e.to_string()))??;
                    audit::record(&ctx.paths, json!({"at": now_ms(), "command": "codes model download", "outcome": "ok", "detail": record["name"]}));
                    json!({"installed": record, "built": detect::BUILT_WITH_DETECTOR})
                }
                ModelAction::Remove => {
                    let v = detect::remove(&ctx.paths)?;
                    audit::record(&ctx.paths, json!({"at": now_ms(), "command": "codes model remove", "outcome": "ok"}));
                    v
                }
            };
            let mut t = String::new();
            if !detect::BUILT_WITH_DETECTOR {
                t.push_str("This build cannot detect codes (it was built without the model runner).\n");
            }
            match detect::installed(&ctx.paths) {
                Some((r, _)) => t.push_str(&format!("Model: {} (version {}), installed.\n", r["name"].as_str().unwrap_or("?"), r["version"])),
                None => t.push_str("No model installed. bridgey codes model download --accept-terms\n"),
            }
            if detect::available(&ctx.paths) {
                t.push_str("Detect codes can be switched on for this install on the phone (it applies within 30 seconds).\n");
            }
            Ok((v, t))
        }
        Command::Codes { latest, service, wait, since, .. } => {
            let wait_ms = wait.as_deref().map(ms).transpose()?.unwrap_or(0);
            let since_ms = ms(&since)?.min(3_600_000);
            let v = ctx.call("codes", json!({"latest": latest, "service": service, "waitMs": wait_ms, "sinceMs": since_ms, "newerThan": if wait_ms > 0 { json!(now) } else { Value::Null }})).await?;
            let mut codes = v["codes"].as_array().cloned().unwrap_or_default();
            if latest {
                codes.truncate(1);
            }
            let mut t = String::new();
            for c in &codes {
                // The phone's clock may run a few seconds ahead of this host's: a code is never "in 8 s".
                let posted = c["postedAt"].as_u64().unwrap_or(0).min(now);
                let source = match c["source"].as_str() {
                    Some("email") => format!("email ({})", c["app"].as_str().unwrap_or("mail")),
                    _ => "sms".into(),
                };
                let mark = if c["latest"] == true { "Latest, use this one" } else if c["replaced"] == true { "Older, replaced" } else { "" };
                // Service names come from message senders: printed without control or escape characters.
                let p = |k: &str, n: usize| session::printable(c[k].as_str().unwrap_or(""), n);
                let source = session::printable(&source, 24);
                t.push_str(&format!("{:<10}  {:<20}  {:<16}  {:<10}  {}\n", p("code", 12), p("service", 64), source, time::relative(posted, now), mark));
            }
            if codes.is_empty() {
                t.push_str("No codes in that time.\n");
            }
            let mut out = v.clone();
            // The JSON gives each code its age and the time as text, so an agent need not compute them.
            out["codes"] = Value::Array(
                codes
                    .into_iter()
                    .map(|mut c| {
                        let posted = c["postedAt"].as_u64().unwrap_or(0);
                        c["ageMs"] = json!(now.saturating_sub(posted));
                        c["postedAtText"] = json!(time::rfc3339(posted));
                        c
                    })
                    .collect(),
            );
            Ok((out, t))
        }
        Command::Audit { since } => {
            let since_ms = now.saturating_sub(ms(&since)?);
            let entries = audit::read(&ctx.paths, since_ms);
            let mut t = String::new();
            for e in &entries {
                t.push_str(&format!("{}  {:<14} {:<16} {:<12} {}\n", time::rfc3339(e["at"].as_u64().unwrap_or(0)), e["command"].as_str().unwrap_or(""), e["device"].as_str().unwrap_or("-"), e["outcome"].as_str().unwrap_or(""), e["caller"]["label"].as_str().or(e["caller"]["parent"].as_str()).unwrap_or("")));
            }
            if entries.is_empty() {
                t.push_str("Nothing in that time.\n");
            }
            Ok((json!({"entries": entries}), t))
        }
        Command::Doctor => {
            let checks = doctor::run(&ctx.paths, &ctx.config, ctx.connect_ms.unwrap_or(10_000)).await;
            let mut t = String::new();
            let mut fails = 0;
            let mut list = Vec::new();
            for c in &checks {
                let tag = match c.level {
                    doctor::Level::Ok => "ok  ",
                    doctor::Level::Warn => "warn",
                    doctor::Level::Fail => {
                        fails += 1;
                        "FAIL"
                    }
                };
                t.push_str(&format!("{tag}  {:<22} {}\n", c.name, c.detail));
                list.push(json!({"name": c.name, "level": tag.trim().to_lowercase(), "detail": c.detail, "data": c.data}));
            }
            Ok((json!({"checks": list, "failures": fails, "exit": if fails > 0 { 1 } else { 0 }}), t))
        }
        Command::Forget { .. } => {
            let v = ctx.call("forget", json!({})).await?;
            Ok((v.clone(), format!("Forgot {} on this side. Forget this device on the phone too.\n", v["device"]["name"].as_str().unwrap_or("it"))))
        }
        Command::Config { action } => config_cmd(ctx, action).await,
        Command::Service { action } => service_cmd(ctx, action).await,
    }
}

fn check_len(name: &str, text: &str, min: usize, max: usize) -> Result<(), CliError> {
    let n = text.chars().count();
    if n < min || n > max {
        return Err(usage(format!("{name} is {min} to {max} characters (got {n})")));
    }
    Ok(())
}

fn answer_text(v: &Value) -> String {
    let a = &v["answer"];
    match (a["label"].as_str(), a["option"].as_str(), a["text"].as_str()) {
        (Some(l), Some(o), _) => format!("{l} ({o})\n"),
        (None, Some(o), _) => format!("{o}\n"),
        (_, _, Some(t)) => format!("{t}\n"),
        _ => "answered\n".into(),
    }
}

async fn ask(ctx: &Ctx, a: AskArgs) -> Result<(Value, String), CliError> {
    check_len("title", &a.title, 1, 120)?;
    if let Some(b) = &a.body {
        check_len("body", b, 0, 1000)?;
    }
    let mut options = Vec::new();
    for o in &a.options {
        let (id, label) = o.split_once('=').ok_or_else(|| usage(format!("--option {o}: use ID=LABEL")))?;
        if id.is_empty() || id.len() > 32 || !id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-') {
            return Err(usage(format!("option ID {id}: 1 to 32 of a-z, 0-9, _ and -")));
        }
        check_len("option label", label, 1, 20)?;
        if options.iter().any(|x: &Value| x["id"] == id) {
            return Err(usage(format!("option ID {id} is used twice")));
        }
        options.push(json!({"id": id, "label": label}));
    }
    let max = if a.text { 2 } else { 3 };
    if options.len() > max || (options.is_empty() && !a.text) {
        return Err(usage(if a.text { "with --text, give at most 2 options" } else { "give 1 to 3 options (-o ID=LABEL) or --text" }));
    }
    if let Some(f) = &a.fail_unless {
        if !options.iter().any(|x| x["id"] == f.as_str()) {
            return Err(usage(format!("--fail-unless {f} is not one of the options")));
        }
    }
    let timeout = ms(&a.timeout)?;
    if timeout > 86_400_000 {
        return Err(usage("--timeout is at most 24h"));
    }
    let v = ctx
        .call(
            "ask",
            json!({"title": a.title, "body": a.body, "options": options, "allowText": a.text, "textHint": a.text_hint, "timeoutMs": timeout,
                   "requireUnlock": a.require_unlock, "failUnless": a.fail_unless, "noWait": a.no_wait, "keepOnTimeout": a.keep_on_timeout, "from": a.from}),
        )
        .await?;
    let t = if a.no_wait { format!("{}\n", v["askId"].as_str().unwrap_or("")) } else { answer_text(&v) };
    Ok((v, t))
}

/// Pairing talks to the daemon both ways: it shows the invite, then the code, and sends the person's answer.
async fn pair(ctx: &Ctx, name: Option<String>, link_only: bool, join: Option<String>) -> Result<(Value, String), CliError> {
    let name = match name {
        Some(n) => {
            let mut c = ctx.config.clone();
            c.set("device_name", &n).map_err(usage)?;
            c.save(&ctx.paths)?;
            Some(n)
        }
        None => None,
    };
    // The code is confirmed by the person at this terminal: asked and answered on /dev/tty, never stdin, so a
    // pipe or a script cannot answer for them.
    if std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty").is_err() {
        return Err(usage("bridgey pair needs a terminal: you confirm the code it shows (there is no way to skip that)"));
    }
    let mut conn = client::connect(&ctx.paths, true).await?;
    conn.send(&json!({"cmd": "pair", "args": {"name": name, "linkOnly": link_only, "join": join}, "caller": audit::caller()})).await.map_err(|e| CliError::new("failed", e.to_string()))?;
    let (reader, mut writer) = conn.split();
    let mut conn_reader = reader;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    loop {
        let mut line = String::new();
        if conn_reader.read_line(&mut line).await.unwrap_or(0) == 0 {
            return Err(CliError::new("failed", "the background agent closed the connection"));
        }
        let Ok(v) = serde_json::from_str::<Value>(line.trim_end()) else { continue };
        if let Some(r) = v.get("result") {
            let t = format!(
                "Paired with {} as \"{}\".\nEvery permission starts off. On the phone, choose what this device may do (Devices, {}, Permissions), then check with: bridgey grants\n",
                r["device"]["name"].as_str().unwrap_or("the phone"),
                r["thisDevice"]["name"].as_str().unwrap_or(""),
                r["thisDevice"]["name"].as_str().unwrap_or("")
            );
            return Ok((r.clone(), t));
        }
        if let Some(e) = v.get("error") {
            return Err(CliError::from_json(e));
        }
        if ctx.jsonl {
            println!("{v}");
        }
        match v["event"].as_str() {
            Some("invite") => {
                let out = if ctx.jsonl { None } else { Some(()) };
                if out.is_some() {
                    let mut err = std::io::stderr();
                    if let Some(qr) = v["qr"].as_str() {
                        let _ = writeln!(err, "\n{qr}");
                    }
                    let _ = writeln!(err, "On the phone: Bridgey, Devices, \"Pair a device away from this network\", then scan this code or paste the link:\n\n  {}\n\nThe invite works once, for 10 minutes. Waiting for the phone...", v["link"].as_str().unwrap_or(""));
                }
            }
            Some("code") => {
                let code: String = v["code"].as_str().unwrap_or("").chars().filter(char::is_ascii_digit).take(6).collect();
                let spaced = format!("{} {}", &code[..3.min(code.len())], &code[3.min(code.len())..]);
                let answer = tokio::task::spawn_blocking(move || {
                    use std::io::BufRead;
                    let Ok(tty) = std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty") else { return false };
                    let mut out = &tty;
                    let _ = write!(out, "\nDoes the phone show {spaced}? [y/N] ");
                    let _ = out.flush();
                    let mut s = String::new();
                    let _ = std::io::BufReader::new(&tty).read_line(&mut s);
                    matches!(s.trim().to_lowercase().as_str(), "y" | "yes")
                })
                .await
                .unwrap_or(false);
                let _ = writer.write_all(format!("{}\n", json!({"confirm": answer, "code": code})).as_bytes()).await;
                if answer {
                    eprintln!("Confirmed here. Confirm on the phone too.");
                }
            }
            Some("attempt_failed") => eprintln!("bridgey: the phone's attempt ended ({}); waiting for another within the invite's time", session::printable(v["reason"].as_str().unwrap_or(""), 64)),
            Some("paired") => eprintln!("Paired. Setting up the connection for away from home..."),
            _ => {}
        }
    }
}

async fn config_cmd(ctx: &Ctx, action: ConfigAction) -> Result<(Value, String), CliError> {
    match action {
        ConfigAction::Get { key } => {
            let v = ctx.config.get(&key).map(|v| serde_json::to_value(v).unwrap_or(Value::Null)).unwrap_or(Value::Null);
            let shown = match key.as_str() {
                "control_url" if v.is_null() => json!(config::DEFAULT_CONTROL_URL),
                "device_name" if v.is_null() => json!(config::default_device_name()),
                _ => v,
            };
            Ok((json!({"key": key, "value": shown}), format!("{}\n", shown.as_str().map(str::to_string).unwrap_or_else(|| shown.to_string()))))
        }
        ConfigAction::Set { key, value } => {
            let mut c = ctx.config.clone();
            c.set(&key, &value).map_err(usage)?;
            c.save(&ctx.paths)?;
            let note = "Saved. A running daemon reads it at its next start (bridgey service install restarts it; systemctl --user restart bridgey).";
            Ok((json!({"key": key, "value": value}), format!("{note}\n")))
        }
        ConfigAction::List => {
            let mut t = String::new();
            for (k, help) in config::KEYS {
                let v = ctx.config.get(k).map(|v| v.to_string()).unwrap_or_else(|| "(default)".into());
                t.push_str(&format!("{k:<18} {v:<36} {help}\n"));
            }
            Ok((json!({"config": serde_json::to_value(&ctx.config.table).unwrap_or(Value::Null), "path": ctx.paths.config}), t))
        }
    }
}

async fn service_cmd(ctx: &Ctx, action: ServiceAction) -> Result<(Value, String), CliError> {
    match action {
        ServiceAction::Install => {
            // A background agent a command started holds the profile's lock: ask it to stop first.
            let _ = client::request(&ctx.paths, "shutdown", json!({}), false, |_| {}).await;
            tokio::time::sleep(std::time::Duration::from_millis(600)).await;
            let v = service::install(&ctx.paths)?;
            let mut t = format!("Installed and started: {}\n", v["installed"].as_str().unwrap_or(""));
            if v["linger"] == false {
                t.push_str("Lingering is off, so the service stops when you log out. Turn it on with: loginctl enable-linger $USER\n");
            }
            t.push_str("Check it with: bridgey doctor\n");
            Ok((v, t))
        }
        ServiceAction::Uninstall => {
            let v = service::uninstall(&ctx.paths)?;
            Ok((v.clone(), if v["removed"] == true { "Service stopped and removed.\n".into() } else { "No service was installed.\n".into() }))
        }
        ServiceAction::Status => {
            let v = service::status(&ctx.paths);
            let t = format!("{}: {}{}\n", v["manager"].as_str().unwrap_or(""), if v["active"] == true { "running" } else if v["installed"] == true { "installed, not running" } else { "not installed" }, if v["linger"] == false { " (lingering off)" } else { "" });
            Ok((v, t))
        }
    }
}
