//! The phone's media buttons for what plays here, through MPRIS (org.mpris.MediaPlayer2), which every Linux player
//! and browser speaks. The player shown is the one playing, else the last one that played. What it plays goes to the
//! phone as `media.state` (rust/client bounds every field).

use std::collections::HashMap;

use serde_json::json;
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

const PREFIX: &str = "org.mpris.MediaPlayer2.";

#[zbus::proxy(interface = "org.mpris.MediaPlayer2.Player", default_path = "/org/mpris/MediaPlayer2")]
trait Player {
    fn play_pause(&self) -> zbus::Result<()>;
    fn pause(&self) -> zbus::Result<()>;
    fn next(&self) -> zbus::Result<()>;
    fn previous(&self) -> zbus::Result<()>;
    fn set_position(&self, track_id: &ObjectPath<'_>, position: i64) -> zbus::Result<()>;
    #[zbus(property)]
    fn playback_status(&self) -> zbus::Result<String>;
    #[zbus(property)]
    fn metadata(&self) -> zbus::Result<HashMap<String, OwnedValue>>;
    #[zbus(property)]
    fn position(&self) -> zbus::Result<i64>;
    #[zbus(property)]
    fn volume(&self) -> zbus::Result<f64>;
    #[zbus(property)]
    fn set_volume(&self, value: f64) -> zbus::Result<()>;
    #[zbus(property)]
    fn can_go_next(&self) -> zbus::Result<bool>;
    #[zbus(property)]
    fn can_go_previous(&self) -> zbus::Result<bool>;
    #[zbus(property)]
    fn can_seek(&self) -> zbus::Result<bool>;
}

#[zbus::proxy(interface = "org.mpris.MediaPlayer2", default_path = "/org/mpris/MediaPlayer2")]
trait Root {
    #[zbus(property)]
    fn identity(&self) -> zbus::Result<String>;
}

#[derive(Default)]
pub struct Media {
    last_playing: Option<String>,
}

fn text(meta: &HashMap<String, OwnedValue>, key: &str) -> String {
    match meta.get(key).map(|v| &**v) {
        Some(Value::Str(s)) => s.to_string(),
        Some(Value::Array(a)) => a.iter().filter_map(|v| if let Value::Str(s) = v { Some(s.to_string()) } else { None }).collect::<Vec<_>>().join(", "),
        _ => String::new(),
    }
}

fn micros(meta: &HashMap<String, OwnedValue>, key: &str) -> i64 {
    match meta.get(key).map(|v| &**v) {
        Some(Value::I64(n)) => *n,
        Some(Value::U64(n)) => *n as i64,
        Some(Value::I32(n)) => *n as i64,
        Some(Value::U32(n)) => *n as i64,
        _ => 0,
    }
}

impl Media {
    async fn players(conn: &zbus::Connection) -> Vec<String> {
        let Ok(dbus) = zbus::fdo::DBusProxy::new(conn).await else { return vec![] };
        let Ok(names) = dbus.list_names().await else { return vec![] };
        let mut out: Vec<String> = names.into_iter().map(|n| n.to_string()).filter(|n| n.starts_with(PREFIX)).collect();
        out.sort();
        out
    }

    /// The player to show and control: the one playing, else the last that played, else the first.
    async fn current(&mut self, conn: &zbus::Connection) -> Option<PlayerProxy<'static>> {
        let names = Self::players(conn).await;
        let mut first = None;
        for name in &names {
            let Ok(p) = PlayerProxy::builder(conn).destination(name.clone()).ok()?.build().await else { continue };
            if p.playback_status().await.ok().as_deref() == Some("Playing") {
                self.last_playing = Some(name.clone());
                return Some(p);
            }
            if first.is_none() {
                first = Some(name.clone());
            }
        }
        let pick = self.last_playing.clone().filter(|n| names.contains(n)).or(first)?;
        PlayerProxy::builder(conn).destination(pick).ok()?.build().await.ok()
    }

    /// The media.state JSON for the phone, or None when nothing plays here.
    pub async fn state(&mut self, conn: &zbus::Connection) -> Option<String> {
        let p = self.current(conn).await?;
        let dest = p.inner().destination().to_string();
        let identity = match RootProxy::builder(conn).destination(dest.clone()).ok()?.build().await {
            Ok(r) => r.identity().await.unwrap_or_default(),
            Err(_) => String::new(),
        };
        let meta = p.metadata().await.unwrap_or_default();
        let playing = p.playback_status().await.ok().as_deref() == Some("Playing");
        let mut controls = vec!["toggle", "pause"];
        if p.can_go_next().await.unwrap_or(false) {
            controls.push("next");
        }
        if p.can_go_previous().await.unwrap_or(false) {
            controls.push("previous");
        }
        if p.can_seek().await.unwrap_or(false) {
            controls.push("seek");
        }
        let volume = p.volume().await.ok();
        if volume.is_some() {
            controls.push("volume");
        }
        let title = text(&meta, "xesam:title");
        if title.is_empty() && !playing {
            return None;
        }
        Some(
            json!({
                "player": if identity.is_empty() { dest.trim_start_matches(PREFIX).to_string() } else { identity },
                "title": title,
                "artist": text(&meta, "xesam:artist"),
                "playing": playing,
                "position": p.position().await.unwrap_or(0) / 1_000_000,
                "duration": micros(&meta, "mpris:length") / 1_000_000,
                "volume": (volume.unwrap_or(0.0).clamp(0.0, 1.0) * 100.0).round() as i64,
                "controls": controls,
                "detail": text(&meta, "xesam:album"),
            })
            .to_string(),
        )
    }

    /// Runs one of the phone's media commands; true once the player took it.
    pub async fn run(&mut self, conn: &zbus::Connection, action: &str, value: Option<i64>) -> bool {
        let Some(p) = self.current(conn).await else { return false };
        let result = match action {
            "toggle" => p.play_pause().await,
            "pause" => p.pause().await,
            "next" => p.next().await,
            "previous" => p.previous().await,
            "seek" => {
                let meta = p.metadata().await.unwrap_or_default();
                let track = match meta.get("mpris:trackid").map(|v| &**v) {
                    Some(Value::ObjectPath(o)) => o.to_owned(),
                    Some(Value::Str(s)) => match ObjectPath::try_from(s.to_string()) {
                        Ok(o) => o,
                        Err(_) => return false,
                    },
                    _ => return false,
                };
                p.set_position(&track, value.unwrap_or(0).max(0) * 1_000_000).await
            }
            "volume" => p.set_volume(value.unwrap_or(0).clamp(0, 100) as f64 / 100.0).await,
            _ => return false,
        };
        result.is_ok()
    }
}
