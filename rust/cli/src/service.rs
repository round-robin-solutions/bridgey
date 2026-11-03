//! `bridgey service install|uninstall|status`: a systemd user unit on Linux, a launchd agent on macOS. Both run
//! `bridgey daemon --service`, which never exits on idle, and restart it if it stops.

use crate::paths::Paths;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Command;

pub const LABEL: &str = "in.roundrobin.bridgey.cli";

fn unit_name(paths: &Paths) -> String {
    if paths.profile == "default" { "bridgey.service".into() } else { format!("bridgey-{}.service", paths.profile) }
}

fn plist_label(paths: &Paths) -> String {
    if paths.profile == "default" { LABEL.into() } else { format!("{LABEL}.{}", paths.profile) }
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

pub fn unit_path(paths: &Paths) -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library/LaunchAgents").join(format!("{}.plist", plist_label(paths)))
    } else {
        std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".config")).join("systemd/user").join(unit_name(paths))
    }
}

fn exe() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().and_then(|p| p.canonicalize()).map_err(|e| format!("cannot find this binary: {e}"))?;
    if exe.starts_with("/tmp") || exe.to_string_lossy().contains("/target/") {
        return Err(format!("{} looks temporary; install bridgey (for example to ~/.local/bin) and run service install from there", exe.display()));
    }
    Ok(exe)
}

fn profile_args(paths: &Paths) -> Vec<String> {
    if paths.profile == "default" { vec![] } else { vec!["--profile".into(), paths.profile.clone()] }
}

pub fn systemd_unit(exe: &str, paths: &Paths) -> String {
    let args = profile_args(paths).join(" ");
    let args = if args.is_empty() { String::new() } else { format!(" {args}") };
    format!(
        "[Unit]\n\
Description=Bridgey agent (Bridgey by Round Robin, profile {profile})\n\
Documentation=https://github.com/round-robin-solutions/bridgey/blob/rr/main/docs/agent-cli-setup.md\n\
After=network-online.target\n\
Wants=network-online.target\n\
\n\
[Service]\n\
Type=simple\n\
ExecStart={exe}{args} daemon --service\n\
Restart=always\n\
RestartSec=5\n\
# Its keys and state are in {root} (0700). Mount sandboxing is left out: user managers often cannot set it up.\n\
NoNewPrivileges=yes\n\
UMask=0077\n\
\n\
[Install]\n\
WantedBy=default.target\n",
        profile = paths.profile,
        root = paths.root.display(),
    )
}

pub fn launchd_plist(exe: &str, paths: &Paths) -> String {
    let mut args = vec![exe.to_string()];
    args.extend(profile_args(paths));
    args.push("daemon".into());
    args.push("--service".into());
    let program: String = args.iter().map(|a| format!("    <string>{}</string>\n", xml(a))).collect();
    let log = paths.state.join("daemon.log");
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
<plist version=\"1.0\">\n\
<dict>\n\
  <key>Label</key>\n  <string>{label}</string>\n\
  <key>ProgramArguments</key>\n  <array>\n{program}  </array>\n\
  <key>RunAtLoad</key>\n  <true/>\n\
  <key>KeepAlive</key>\n  <true/>\n\
  <key>ProcessType</key>\n  <string>Background</string>\n\
  <key>Umask</key>\n  <integer>63</integer>\n\
  <key>StandardErrorPath</key>\n  <string>{log}</string>\n\
  <key>StandardOutPath</key>\n  <string>{log}</string>\n\
</dict>\n\
</plist>\n",
        label = plist_label(paths),
        log = xml(&log.to_string_lossy()),
    )
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn run(cmd: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(cmd).args(args).output().map_err(|e| format!("{cmd}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        Err(format!("{cmd} {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))
    }
}

pub fn install(paths: &Paths) -> Result<Value, String> {
    let exe = exe()?;
    let exe_s = exe.to_string_lossy().to_string();
    let path = unit_path(paths);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    paths.ensure().map_err(|e| e.to_string())?;
    if cfg!(target_os = "macos") {
        std::fs::write(&path, launchd_plist(&exe_s, paths)).map_err(|e| format!("{}: {e}", path.display()))?;
        let uid = unsafe { libc::getuid() };
        let domain = format!("gui/{uid}");
        let _ = run("launchctl", &["bootout", &format!("{domain}/{}", plist_label(paths))]);
        run("launchctl", &["bootstrap", &domain, &path.to_string_lossy()])?;
        Ok(json!({"installed": path.to_string_lossy(), "manager": "launchd", "label": plist_label(paths), "binary": exe_s}))
    } else {
        std::fs::write(&path, systemd_unit(&exe_s, paths)).map_err(|e| format!("{}: {e}", path.display()))?;
        run("systemctl", &["--user", "daemon-reload"])?;
        run("systemctl", &["--user", "enable", &unit_name(paths)])?;
        run("systemctl", &["--user", "restart", &unit_name(paths)])?;
        let linger = linger();
        Ok(json!({"installed": path.to_string_lossy(), "manager": "systemd", "unit": unit_name(paths), "binary": exe_s, "linger": linger}))
    }
}

pub fn uninstall(paths: &Paths) -> Result<Value, String> {
    let path = unit_path(paths);
    if cfg!(target_os = "macos") {
        let uid = unsafe { libc::getuid() };
        let _ = run("launchctl", &["bootout", &format!("gui/{uid}/{}", plist_label(paths))]);
    } else {
        let _ = run("systemctl", &["--user", "disable", "--now", &unit_name(paths)]);
    }
    let existed = std::fs::remove_file(&path).is_ok();
    if !cfg!(target_os = "macos") {
        let _ = run("systemctl", &["--user", "daemon-reload"]);
    }
    Ok(json!({"removed": existed, "path": path.to_string_lossy()}))
}

/// Linger: whether the user's services run without a login session (Linux).
pub fn linger() -> Option<bool> {
    if cfg!(target_os = "macos") {
        return None;
    }
    let user = std::env::var("USER").ok()?;
    run("loginctl", &["show-user", &user, "--property=Linger", "--value"]).ok().map(|v| v == "yes")
}

pub fn status(paths: &Paths) -> Value {
    let path = unit_path(paths);
    let installed = path.exists();
    if cfg!(target_os = "macos") {
        let uid = unsafe { libc::getuid() };
        let running = run("launchctl", &["print", &format!("gui/{uid}/{}", plist_label(paths))]).map(|o| o.contains("state = running")).unwrap_or(false);
        json!({"manager": "launchd", "installed": installed, "path": path.to_string_lossy(), "active": running, "enabled": installed})
    } else {
        let active = run("systemctl", &["--user", "is-active", &unit_name(paths)]).map(|s| s == "active").unwrap_or(false);
        let enabled = run("systemctl", &["--user", "is-enabled", &unit_name(paths)]).map(|s| s == "enabled").unwrap_or(false);
        json!({"manager": "systemd", "installed": installed, "path": path.to_string_lossy(), "unit": unit_name(paths), "active": active, "enabled": enabled, "linger": linger()})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unit_files_name_the_profile() {
        let paths = Paths::resolve(Some("ci")).unwrap();
        let unit = systemd_unit("/home/u/.local/bin/bridgey", &paths);
        assert!(unit.contains("ExecStart=/home/u/.local/bin/bridgey --profile ci daemon --service"));
        assert!(unit.contains("WantedBy=default.target"));
        let plist = launchd_plist("/usr/local/bin/bridgey", &paths);
        assert!(plist.contains("<string>in.roundrobin.bridgey.cli.ci</string>"));
        assert!(plist.contains("<string>--service</string>"));
    }
}
