//! Start at sign-in through XDG autostart (~/.config/autostart), which GNOME, KDE Plasma, Xfce, Cinnamon, MATE and
//! the systemd user session all read. Bridgey starts in the background there, without its window.

use std::path::{Path, PathBuf};

use crate::edition;
use crate::paths;

pub fn file() -> PathBuf {
    paths::config_home().join("autostart").join(format!("{}.desktop", edition::APP_ID))
}

/// Quotes a path for a desktop entry's Exec key (the spec's double-quote rules).
pub fn exec_quote(path: &Path) -> String {
    let s = path.to_string_lossy();
    let mut out = String::from("\"");
    for c in s.chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

pub fn entry(launcher: &Path) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName={}\nExec={} --background\nIcon={}\nTerminal=false\nX-GNOME-Autostart-enabled=true\nX-KDE-autostart-after=panel\nNoDisplay=true\n",
        edition::DISPLAY_NAME,
        exec_quote(launcher),
        edition::APP_ID
    )
}

/// Writes or removes the autostart entry. A test profile never touches it.
pub fn apply(on: bool) -> std::io::Result<()> {
    if paths::is_separate_profile() {
        return Ok(());
    }
    let path = file();
    if on {
        std::fs::create_dir_all(path.parent().unwrap())?;
        let text = entry(&paths::launcher());
        if std::fs::read_to_string(&path).ok().as_deref() != Some(text.as_str()) {
            std::fs::write(&path, text)?;
        }
    } else if path.exists() {
        std::fs::remove_file(&path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_paths_are_quoted() {
        assert_eq!(exec_quote(Path::new("/home/a/Apps/Bridgey RR.AppImage")), "\"/home/a/Apps/Bridgey RR.AppImage\"");
        assert_eq!(exec_quote(Path::new("/tmp/a\"b$c")), "\"/tmp/a\\\"b\\$c\"");
        assert!(entry(Path::new("/x/B.AppImage")).contains("Exec=\"/x/B.AppImage\" --background\n"));
    }
}
