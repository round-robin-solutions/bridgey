//! Find device: a chime this computer plays until someone stops it. It goes through the sound server's own player
//! (pw-play for PipeWire, paplay for PulseAudio, aplay for ALSA), so Bridgey links no audio library; the sound is made
//! here as a small WAV file in the cache.

use std::path::PathBuf;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};

/// A 1.2 s two-note chime, 16-bit mono at 22,050 Hz, fading in and out.
pub fn chime_wav() -> Vec<u8> {
    let rate = 22_050u32;
    let mut samples: Vec<i16> = Vec::new();
    for (freq, secs) in [(880.0f32, 0.35f32), (1318.5, 0.45), (0.0, 0.4)] {
        let n = (rate as f32 * secs) as usize;
        for i in 0..n {
            let t = i as f32 / rate as f32;
            let env = (t / 0.02).min(1.0) * ((secs - t) / 0.08).clamp(0.0, 1.0);
            let v = if freq > 0.0 { (t * freq * std::f32::consts::TAU).sin() * 0.6 * env } else { 0.0 };
            samples.push((v * i16::MAX as f32) as i16);
        }
    }
    let data_len = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

/// The player process of the chime now playing.
type Slot = Arc<Mutex<Option<Child>>>;

#[derive(Default, Clone)]
pub struct Ringer {
    playing: Arc<Mutex<Option<Slot>>>,
}

fn player() -> Option<&'static str> {
    ["pw-play", "paplay", "aplay"].into_iter().find(|p| std::env::var_os("PATH").is_some_and(|path| std::env::split_paths(&path).any(|d| d.join(p).is_file())))
}

impl Ringer {
    /// Plays the chime again and again (for at most two minutes) until `stop`. False when no player was found.
    pub fn start(&self) -> bool {
        self.stop();
        let Some(player) = player() else { return false };
        let path: PathBuf = crate::paths::cache_dir().join("find-device.wav");
        if !path.exists() {
            let _ = std::fs::create_dir_all(path.parent().unwrap());
            if std::fs::write(&path, chime_wav()).is_err() {
                return false;
            }
        }
        let child: Slot = Arc::new(Mutex::new(None));
        *self.playing.lock().unwrap() = Some(child.clone());
        let me = self.clone();
        std::thread::spawn(move || {
            let until = std::time::Instant::now() + std::time::Duration::from_secs(120);
            while std::time::Instant::now() < until {
                {
                    let current = me.playing.lock().unwrap();
                    if !current.as_ref().is_some_and(|c| Arc::ptr_eq(c, &child)) {
                        return;
                    }
                }
                let spawned = super::launch::command(player).arg(&path).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
                let Ok(c) = spawned else { return };
                *child.lock().unwrap() = Some(c);
                loop {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                    let mut slot = child.lock().unwrap();
                    match slot.as_mut().map(|c| c.try_wait()) {
                        Some(Ok(Some(_))) | Some(Err(_)) | None => break,
                        Some(Ok(None)) => {}
                    }
                }
            }
        });
        true
    }

    pub fn stop(&self) {
        if let Some(child) = self.playing.lock().unwrap().take() {
            if let Some(mut c) = child.lock().unwrap().take() {
                let _ = c.kill();
                let _ = c.wait();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_chime_is_a_valid_wav() {
        let wav = super::chime_wav();
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..16], b"WAVEfmt ");
        let len = u32::from_le_bytes(wav[40..44].try_into().unwrap()) as usize;
        assert_eq!(wav.len(), 44 + len);
    }
}
