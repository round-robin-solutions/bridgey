//! Clocks, durations (`30s`, `10m`, `2h`, `7d`) and dates, without a date library.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// `30s`, `10m`, `2h`, `7d`, `500ms`, or a bare number of seconds.
pub fn parse_duration(text: &str) -> Result<Duration, String> {
    let t = text.trim();
    let (number, unit) = match t.find(|c: char| !c.is_ascii_digit()) {
        Some(i) => (&t[..i], &t[i..]),
        None => (t, "s"),
    };
    let n: u64 = number.parse().map_err(|_| format!("not a duration: {text} (use 30s, 10m, 2h or 7d)"))?;
    let factor = match unit {
        "ms" => 1,
        "s" => 1000,
        "m" => 60_000,
        "h" => 3_600_000,
        "d" => 86_400_000,
        _ => return Err(format!("not a duration: {text} (use 30s, 10m, 2h or 7d)")),
    };
    let ms = n.checked_mul(factor).filter(|ms| *ms <= 366 * 86_400_000).ok_or_else(|| format!("{text} is too long"))?;
    Ok(Duration::from_millis(ms))
}

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian (Howard Hinnant's algorithm).
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// `2026-11-03T12:04:31Z`.
pub fn rfc3339(ms: u64) -> String {
    let secs = (ms / 1000) as i64;
    let (y, mo, d) = civil(secs.div_euclid(86_400));
    let rem = secs.rem_euclid(86_400);
    format!("{y:04}-{mo:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

/// "now", "40 s ago", "2 min ago", "3 h ago", "2 days ago" (and "in 5 min" for the future).
pub fn relative(ms: u64, now: u64) -> String {
    if ms > now + 1000 {
        let d = (ms - now) / 1000;
        return if d < 60 { format!("in {d} s") } else if d < 3600 { format!("in {} min", d / 60) } else if d < 86_400 { format!("in {} h", d / 3600) } else { format!("in {} days", d / 86_400) };
    }
    let d = now.saturating_sub(ms) / 1000;
    match d {
        0..=4 => "now".into(),
        5..=59 => format!("{d} s ago"),
        60..=3599 => format!("{} min ago", d / 60),
        3600..=86_399 => format!("{} h ago", d / 3600),
        _ => format!("{} days ago", d / 86_400),
    }
}

/// What a person reads for an expiry: `15:40 UTC` today, otherwise `10 Nov 15:40 UTC`.
pub fn short(ms: u64, now: u64) -> String {
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let secs = (ms / 1000) as i64;
    let day = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let hm = format!("{:02}:{:02} UTC", rem / 3600, rem % 3600 / 60);
    if day == (now / 1000) as i64 / 86_400 {
        hm
    } else {
        let (_, m, d) = civil(day);
        format!("{d} {} {hm}", MONTHS[(m - 1) as usize])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        assert_eq!(parse_duration("30s").unwrap(), Duration::from_secs(30));
        assert_eq!(parse_duration("10m").unwrap(), Duration::from_secs(600));
        assert_eq!(parse_duration("2h").unwrap(), Duration::from_secs(7200));
        assert_eq!(parse_duration("7d").unwrap(), Duration::from_secs(604_800));
        assert_eq!(parse_duration("45").unwrap(), Duration::from_secs(45));
        assert!(parse_duration("soon").is_err());
        assert!(parse_duration("5y").is_err());
    }

    #[test]
    fn dates() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(1_761_400_000_000), "2025-10-25T13:46:40Z");
        assert_eq!(rfc3339(951_782_400_000), "2000-02-29T00:00:00Z");
        assert_eq!(relative(1000, 1000), "now");
        assert_eq!(relative(0, 120_000), "2 min ago");
        assert_eq!(short(1_761_400_000_000, 1_761_400_000_000), "13:46 UTC");
        assert_eq!(short(1_761_400_000_000, 1_761_500_000_000), "25 Oct 13:46 UTC");
    }
}
