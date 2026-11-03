//! The command side of the agent socket. With no daemon running, the first command starts one in the
//! background (it exits after `daemon.idle_exit` without use); `bridgey service install` keeps one running.

use crate::errors::CliError;
use crate::ipc::Conn;
use crate::paths::Paths;
use serde_json::{json, Value};
use std::os::unix::process::CommandExt;
use std::time::Duration;

pub async fn connect(paths: &Paths, start: bool) -> Result<Conn, CliError> {
    match Conn::connect(&paths.socket()).await {
        Ok(c) => return Ok(c),
        Err(e) if !start => return Err(CliError::new("failed", format!("no bridgey daemon is running ({e})"))),
        Err(_) => {}
    }
    spawn_daemon(paths)?;
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if let Ok(c) = Conn::connect(&paths.socket()).await {
            return Ok(c);
        }
        if std::time::Instant::now() > deadline {
            let log = paths.state.join("daemon.log");
            return Err(CliError::new("failed", format!("the background agent did not start; see {}", log.display())));
        }
    }
}

fn spawn_daemon(paths: &Paths) -> Result<(), CliError> {
    paths.ensure().map_err(|e| CliError::new("failed", e.to_string()))?;
    let exe = std::env::current_exe().map_err(|e| CliError::new("failed", e.to_string()))?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths.state.join("daemon.log"))
        .map_err(|e| CliError::new("failed", e.to_string()))?;
    let mut cmd = std::process::Command::new(exe);
    if paths.profile != "default" {
        cmd.args(["--profile", &paths.profile]);
    }
    cmd.arg("daemon").stdin(std::process::Stdio::null()).stdout(log.try_clone().map_err(|e| CliError::new("failed", e.to_string()))?).stderr(log);
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            libc::umask(0o077);
            Ok(())
        });
    }
    cmd.spawn().map_err(|e| CliError::new("failed", format!("cannot start the background agent: {e}")))?;
    if std::env::var_os("BRIDGEY_QUIET").is_none() {
        eprintln!("bridgey: started a background agent (it stops after 10 minutes unused). To keep one running: bridgey service install");
    }
    Ok(())
}

/// One request: the events it streamed (passed to `on_event`) and its result.
pub async fn request(paths: &Paths, cmd: &str, args: Value, start: bool, mut on_event: impl FnMut(&Value)) -> Result<Value, CliError> {
    let mut conn = connect(paths, start).await?;
    conn.send(&json!({"cmd": cmd, "args": args, "caller": crate::audit::caller()})).await.map_err(|e| CliError::new("failed", e.to_string()))?;
    loop {
        let Some(line) = conn.recv().await else { return Err(CliError::new("failed", "the background agent closed the connection")) };
        if let Some(r) = line.get("result") {
            return Ok(r.clone());
        }
        if let Some(e) = line.get("error") {
            return Err(CliError::from_json(e));
        }
        on_event(&line);
    }
}
