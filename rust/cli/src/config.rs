//! `config.toml`: the one settings file (agent-cli.md section 10). Unknown keys are kept as they are.

use crate::paths::{write_private, Paths};
use std::time::Duration;
use toml::{Table, Value};

/// The edition's control service (`CONNECT_CONTROL_URL` in rr-edition.properties).
pub const DEFAULT_CONTROL_URL: &str = "wss://connect.roundrobin.in/v1/ws";

pub const KEYS: &[(&str, &str)] = &[
    ("device_name", "the name the phone shows for this install"),
    ("default_device", "the device commands use without -d"),
    ("control_url", "the Connect anywhere control service"),
    ("udp_port", "0 = any free port; 42458 lets phones reach this host directly when the firewall allows it"),
    ("output", "text or json"),
    ("timeouts.connect", "how long a command waits for a route (10s)"),
    ("timeouts.ask", "how long ask waits by default (30m)"),
    ("tcp_port", "the port bridgey pair --allow listens on (42458)"),
    ("daemon.idle_exit", "how long a background agent started by a command stays after its last use (10m); the service never exits"),
];

#[derive(Clone, Debug)]
pub struct Config {
    pub table: Table,
}

impl Config {
    pub fn load(paths: &Paths) -> Result<Config, String> {
        match std::fs::read_to_string(&paths.config) {
            Ok(text) => text.parse::<Table>().map(|table| Config { table }).map_err(|e| format!("{}: {e}", paths.config.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config { table: Table::new() }),
            Err(e) => Err(format!("{}: {e}", paths.config.display())),
        }
    }

    pub fn save(&self, paths: &Paths) -> Result<(), String> {
        paths.ensure().map_err(|e| format!("{}: {e}", paths.root.display()))?;
        let text = toml::to_string(&self.table).map_err(|e| e.to_string())?;
        write_private(&paths.config, text.as_bytes()).map_err(|e| format!("{}: {e}", paths.config.display()))
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        let mut parts = key.split('.');
        let first = parts.next()?;
        let mut v = self.table.get(first)?;
        for p in parts {
            v = v.as_table()?.get(p)?;
        }
        Some(v)
    }

    pub fn str(&self, key: &str) -> Option<String> {
        self.get(key).and_then(Value::as_str).map(str::to_string).filter(|s| !s.is_empty())
    }

    pub fn set(&mut self, key: &str, raw: &str) -> Result<(), String> {
        if !KEYS.iter().any(|(k, _)| *k == key) {
            return Err(format!("unknown key {key}; keys: {}", KEYS.iter().map(|(k, _)| *k).collect::<Vec<_>>().join(", ")));
        }
        let value = match key {
            "udp_port" => Value::Integer(raw.parse::<u16>().map_err(|_| "udp_port is 0 to 65535")?.into()),
            "tcp_port" => Value::Integer(raw.parse::<u16>().ok().filter(|p| *p > 0).ok_or("tcp_port is 1 to 65535")?.into()),
            "output" if raw != "text" && raw != "json" => return Err("output is text or json".into()),
            "timeouts.connect" | "timeouts.ask" | "daemon.idle_exit" => {
                crate::time::parse_duration(raw)?;
                Value::String(raw.into())
            }
            "control_url" if !(raw.starts_with("wss://") || raw.starts_with("ws://") || raw.is_empty()) => return Err("control_url starts with wss://".into()),
            "device_name" if raw.chars().count() > 64 || raw.trim().is_empty() => return Err("device_name is 1 to 64 characters".into()),
            _ => Value::String(raw.into()),
        };
        let (section, name) = match key.split_once('.') {
            Some((s, n)) => (Some(s), n),
            None => (None, key),
        };
        let table = match section {
            Some(s) => self.table.entry(s).or_insert_with(|| Value::Table(Table::new())).as_table_mut().ok_or("not a table")?,
            None => &mut self.table,
        };
        table.insert(name.into(), value);
        Ok(())
    }

    pub fn control_url(&self) -> String {
        match self.get("control_url").and_then(Value::as_str) {
            Some(url) => url.to_string(),
            None => DEFAULT_CONTROL_URL.into(),
        }
    }

    pub fn udp_port(&self) -> u16 {
        self.get("udp_port").and_then(Value::as_integer).and_then(|p| u16::try_from(p).ok()).unwrap_or(0)
    }

    pub fn duration(&self, key: &str, default: Duration) -> Duration {
        self.str(key).and_then(|s| crate::time::parse_duration(&s).ok()).unwrap_or(default)
    }

    pub fn json_output(&self) -> bool {
        self.str("output").as_deref() == Some("json")
    }
}

/// The default name: the pretty hostname (`hostnamectl --pretty`; macOS: `scutil --get ComputerName`), else the
/// hostname.
pub fn default_device_name() -> String {
    let run = |cmd: &str, args: &[&str]| {
        std::process::Command::new(cmd)
            .args(args)
            .stderr(std::process::Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty())
    };
    let pretty = if cfg!(target_os = "macos") { run("scutil", &["--get", "ComputerName"]) } else { run("hostnamectl", &["--pretty"]) };
    let name = pretty
        .or_else(|| {
            std::fs::read_to_string("/etc/machine-info")
                .ok()
                .and_then(|t| t.lines().find_map(|l| l.strip_prefix("PRETTY_HOSTNAME=").map(|v| v.trim_matches('"').to_string())))
                .filter(|s| !s.is_empty())
        })
        .or_else(|| run("hostname", &[]))
        .unwrap_or_else(|| "bridgey agent".into());
    name.chars().take(64).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_url_matches_the_edition() {
        let props = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../rr-edition.properties")).unwrap();
        let url = props.lines().find_map(|l| l.strip_prefix("CONNECT_CONTROL_URL=")).unwrap();
        assert_eq!(url, DEFAULT_CONTROL_URL);
    }

    #[test]
    fn set_and_get() {
        let mut c = Config { table: Table::new() };
        c.set("timeouts.connect", "20s").unwrap();
        c.set("udp_port", "42458").unwrap();
        assert_eq!(c.duration("timeouts.connect", Duration::ZERO), Duration::from_secs(20));
        assert_eq!(c.udp_port(), 42458);
        assert!(c.set("nope", "x").is_err());
        assert!(c.set("output", "xml").is_err());
        assert_eq!(c.control_url(), DEFAULT_CONTROL_URL);
    }
}
