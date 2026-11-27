//! Bridgey in the desktop when it runs as an AppImage, which installs nothing by itself:
//!
//! - the app menu: a desktop entry and icons in ~/.local/share, pointing at wherever the AppImage is now (rewritten at
//!   each start, so moving the file keeps it working). GNOME also needs this entry to show Bridgey's notifications
//!   under its name;
//! - Send to Bridgey: a script in Files (Nautilus) and Nemo's script menus, and a service menu in Dolphin.
//!
//! A test profile (BRIDGEY_DATA_DIR) never touches any of them.

use std::path::{Path, PathBuf};

use super::autostart::exec_quote;
use crate::edition;
use crate::i18n::t;
use crate::paths;

fn write_if_changed(path: &Path, text: &str, executable: bool) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if std::fs::read_to_string(path).ok().as_deref() != Some(text) {
        std::fs::write(path, text)?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = if executable { 0o755 } else { 0o644 };
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
    }
    Ok(())
}

pub fn desktop_entry(launcher: &Path) -> String {
    let exec = exec_quote(launcher);
    format!(
        "[Desktop Entry]\nType=Application\nName={name}\nGenericName={generic}\nComment={comment}\nComment[ru]={comment_ru}\nExec={exec} %F\nIcon={id}\nTerminal=false\nCategories=Network;Utility;\nKeywords=phone;android;clipboard;files;notifications;\nStartupNotify=true\nStartupWMClass={id}\nSingleMainWindow=true\nX-GNOME-UsesNotifications=true\nActions=send;pair;\n\n[Desktop Action send]\nName={send}\nName[ru]={send_ru}\nExec={exec} --send-dialog\n\n[Desktop Action pair]\nName={pair}\nName[ru]={pair_ru}\nExec={exec} --pair\n",
        name = edition::DISPLAY_NAME,
        generic = "Phone link",
        comment = "Clipboard, files and notifications between your phone and this computer",
        comment_ru = "Буфер обмена, файлы и уведомления между телефоном и этим компьютером",
        exec = exec,
        id = edition::APP_ID,
        send = "Send files",
        send_ru = "Отправить файлы",
        pair = "Pair a new device",
        pair_ru = "Связать новое устройство",
    )
}

fn nautilus_script(launcher: &Path) -> String {
    format!("#!/bin/sh\n# Bridgey by Round Robin: sends the selected files to your phone. Settings > Sharing > Files turns this off.\nexec {} --send \"$@\"\n", exec_quote(launcher))
}

fn dolphin_menu(launcher: &Path) -> String {
    format!(
        "[Desktop Entry]\nType=Service\nMimeType=application/octet-stream;all/allfiles;\nActions=sendToBridgey;\nX-KDE-Priority=TopLevel\n\n[Desktop Action sendToBridgey]\nName=Send to Bridgey\nName[ru]=Отправить в Bridgey\nIcon={}\nExec={} --send %F\n",
        edition::APP_ID,
        exec_quote(launcher)
    )
}

pub fn applications_entry() -> PathBuf {
    paths::data_home().join("applications").join(format!("{}.desktop", edition::APP_ID))
}

fn script_paths() -> Vec<PathBuf> {
    let name = t("sendto.script_name");
    vec![paths::data_home().join("nautilus/scripts").join(name), paths::data_home().join("nemo/scripts").join(name)]
}

fn dolphin_path() -> PathBuf {
    paths::data_home().join("kio/servicemenus").join(format!("{}.desktop", edition::APP_ID))
}

/// Copies the icons out of the AppImage into ~/.local/share/icons, where the app menu and the notification server
/// look.
fn install_icons() -> std::io::Result<()> {
    let src = paths::resources().join("icons/hicolor");
    if !src.is_dir() {
        return Ok(());
    }
    let dest = paths::data_home().join("icons/hicolor");
    for rel in [format!("scalable/apps/{}.svg", edition::APP_ID), format!("symbolic/apps/{}-symbolic.svg", edition::APP_ID)] {
        let from = src.join(&rel);
        if let Ok(bytes) = std::fs::read(&from) {
            let to = dest.join(&rel);
            std::fs::create_dir_all(to.parent().unwrap())?;
            if std::fs::read(&to).ok().as_deref() != Some(bytes.as_slice()) {
                std::fs::write(to, bytes)?;
            }
        }
    }
    Ok(())
}

pub fn apply(app_menu: bool, file_manager: bool) -> std::io::Result<()> {
    if paths::is_separate_profile() {
        return Ok(());
    }
    let launcher = paths::launcher();
    let entry = applications_entry();
    if app_menu {
        install_icons()?;
        write_if_changed(&entry, &desktop_entry(&launcher), false)?;
    } else if entry.exists() {
        std::fs::remove_file(entry)?;
    }
    // Remove scripts under an old name (the language changed).
    for dir in [paths::data_home().join("nautilus/scripts"), paths::data_home().join("nemo/scripts")] {
        for name in ["Send to Bridgey", "Отправить в Bridgey"] {
            let p = dir.join(name);
            if p.exists() && !script_paths().contains(&p) {
                let _ = std::fs::remove_file(p);
            }
        }
    }
    for path in script_paths() {
        if file_manager {
            // Only where that file manager keeps its folder, so nothing appears for a file manager not installed.
            if path.parent().and_then(Path::parent).is_some_and(Path::is_dir) {
                write_if_changed(&path, &nautilus_script(&launcher), true)?;
            }
        } else if path.exists() {
            std::fs::remove_file(path)?;
        }
    }
    let dolphin = dolphin_path();
    if file_manager && which("dolphin") {
        write_if_changed(&dolphin, &dolphin_menu(&launcher), true)?;
    } else if !file_manager && dolphin.exists() {
        std::fs::remove_file(dolphin)?;
    }
    Ok(())
}

fn which(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| std::env::split_paths(&path).any(|d| d.join(program).is_file()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_point_at_the_launcher() {
        let e = desktop_entry(Path::new("/home/a/Apps/Bridgey.AppImage"));
        assert!(e.contains("Exec=\"/home/a/Apps/Bridgey.AppImage\" %F\n"));
        assert!(e.contains(&format!("Icon={}\n", edition::APP_ID)));
        assert!(e.contains("[Desktop Action send]"));
        assert!(nautilus_script(Path::new("/x/B.AppImage")).ends_with("exec \"/x/B.AppImage\" --send \"$@\"\n"));
        assert!(dolphin_menu(Path::new("/x/B.AppImage")).contains("Exec=\"/x/B.AppImage\" --send %F"));
    }
}
