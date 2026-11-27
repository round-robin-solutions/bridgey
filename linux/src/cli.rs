//! The command line. A second `bridgey-linux` never starts another app: GApplication hands its arguments to the one
//! running (single instance), which shows its window or does what they ask.

use std::path::PathBuf;

#[derive(Debug, Default, PartialEq)]
pub struct Args {
    /// Start without the window (sign-in).
    pub background: bool,
    pub pair: bool,
    pub settings: bool,
    pub send_dialog: bool,
    pub quit: bool,
    /// Files to send (Send to Bridgey in the file manager, or `--send <files>`); also bare file arguments (%F).
    pub send: Vec<PathBuf>,
    pub unknown: Option<String>,
}

pub const HELP: &str = "Usage: bridgey-linux [--background] [--pair] [--settings] [--send-dialog] [--send FILE...] [--quit] [--version]";

pub fn parse(args: &[String], cwd: Option<&std::path::Path>) -> Args {
    let mut out = Args::default();
    let mut files = false;
    for a in args {
        if files && !a.starts_with("--") {
            out.send.push(absolute(a, cwd));
            continue;
        }
        match a.as_str() {
            "--background" | "--hidden" => out.background = true,
            "--pair" => out.pair = true,
            "--settings" => out.settings = true,
            "--send-dialog" => out.send_dialog = true,
            "--quit" => out.quit = true,
            "--send" => files = true,
            "--show" => {}
            other if other.starts_with('-') => {
                out.unknown = Some(other.to_string());
            }
            // A file opened with Bridgey (Exec=... %F).
            other => out.send.push(absolute(&file_uri(other), cwd)),
        }
    }
    out
}

fn file_uri(arg: &str) -> String {
    arg.strip_prefix("file://").map(|p| p.to_string()).unwrap_or_else(|| arg.to_string())
}

fn absolute(path: &str, cwd: Option<&std::path::Path>) -> PathBuf {
    let p = PathBuf::from(path);
    match cwd {
        Some(c) if p.is_relative() => c.join(p),
        _ => p,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn arguments_parse() {
        let cwd = std::path::Path::new("/home/a");
        let a = parse(&s(&["--send", "x.jpg", "/tmp/y.pdf"]), Some(cwd));
        assert_eq!(a.send, vec![PathBuf::from("/home/a/x.jpg"), PathBuf::from("/tmp/y.pdf")]);
        assert!(parse(&s(&["--background"]), None).background);
        assert!(parse(&s(&["--quit"]), None).quit);
        assert_eq!(parse(&s(&["--frobnicate"]), None).unknown.as_deref(), Some("--frobnicate"));
        assert_eq!(parse(&s(&["file:///tmp/z.png"]), None).send, vec![PathBuf::from("/tmp/z.png")]);
        assert_eq!(parse(&s(&[]), None), Args::default());
    }
}
