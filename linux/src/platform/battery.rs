//! This computer's battery for paired devices, from /sys/class/power_supply (the kernel's view, the same source
//! UPower reads). A desktop has none and reports nothing.

use std::path::Path;

/// (level 0 to 100, charging) of the system battery, or None. `BRIDGEY_BATTERY=level,charging` stands in for tests.
pub fn read() -> Option<(u8, bool)> {
    if let Ok(v) = std::env::var("BRIDGEY_BATTERY") {
        let (l, c) = v.split_once(',')?;
        return Some((l.trim().parse::<u8>().ok()?.min(100), c.trim() == "1"));
    }
    read_from(Path::new("/sys/class/power_supply"))
}

pub fn read_from(root: &Path) -> Option<(u8, bool)> {
    let mut total_now = 0u64;
    let mut total_full = 0u64;
    let mut levels = Vec::new();
    let mut charging = false;
    let mut entries: Vec<_> = std::fs::read_dir(root).ok()?.flatten().map(|e| e.path()).collect();
    entries.sort();
    for dir in entries {
        let read = |name: &str| std::fs::read_to_string(dir.join(name)).ok().map(|s| s.trim().to_string());
        if read("type").as_deref() != Some("Battery") {
            continue;
        }
        // A mouse's or headset's battery says scope Device; only the system's own counts.
        if read("scope").as_deref() == Some("Device") {
            continue;
        }
        if read("present").as_deref() == Some("0") {
            continue;
        }
        let status = read("status").unwrap_or_default();
        if status == "Charging" || status == "Full" {
            charging = true;
        }
        let now = read("energy_now").or_else(|| read("charge_now")).and_then(|v| v.parse::<u64>().ok());
        let full = read("energy_full").or_else(|| read("charge_full")).and_then(|v| v.parse::<u64>().ok());
        match (now, full) {
            (Some(n), Some(f)) if f > 0 => {
                total_now += n;
                total_full += f;
            }
            _ => {
                if let Some(c) = read("capacity").and_then(|v| v.parse::<u64>().ok()) {
                    levels.push(c.min(100));
                }
            }
        }
    }
    if let Some(level) = (total_now * 100 + total_full / 2).checked_div(total_full) {
        return Some((level.min(100) as u8, charging));
    }
    if !levels.is_empty() {
        return Some(((levels.iter().sum::<u64>() / levels.len() as u64) as u8, charging));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn supply(root: &Path, name: &str, files: &[(&str, &str)]) {
        let d = root.join(name);
        std::fs::create_dir_all(&d).unwrap();
        for (k, v) in files {
            std::fs::write(d.join(k), v).unwrap();
        }
    }

    #[test]
    fn laptops_report_and_desktops_and_mice_do_not() {
        let root = std::env::temp_dir().join(format!("bridgey-battery-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        supply(&root, "AC", &[("type", "Mains"), ("online", "1")]);
        supply(&root, "hidpp_battery_0", &[("type", "Battery"), ("scope", "Device"), ("capacity", "5"), ("status", "Discharging")]);
        assert_eq!(read_from(&root), None, "a mouse is not this computer");
        supply(&root, "BAT0", &[("type", "Battery"), ("energy_now", "30000"), ("energy_full", "40000"), ("status", "Discharging")]);
        supply(&root, "BAT1", &[("type", "Battery"), ("energy_now", "10000"), ("energy_full", "20000"), ("status", "Charging")]);
        assert_eq!(read_from(&root), Some((67, true)));
        std::fs::remove_dir_all(&root).unwrap();
    }
}
