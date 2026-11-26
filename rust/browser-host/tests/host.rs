//! The real helper binary over stdio, against a fake app on a Unix socket (macOS and Linux).
#![cfg(unix)]

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

const CHROME: &str = "chrome-extension://aajelmcjgfjbhemgofnompobgbcdfcin/";

struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Folder {
        let path = std::env::temp_dir().join(format!("bbh-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Folder(path)
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A fake app: answers each connection with `answer` and reports the request line it got.
fn fake_app(path: &Path, answer: &'static str) -> mpsc::Receiver<String> {
    let listener = UnixListener::bind(path).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let mut line = String::new();
            BufReader::new(&stream).read_line(&mut line).unwrap();
            let _ = tx.send(line);
            stream.write_all(answer.as_bytes()).unwrap();
            stream.write_all(b"\n").unwrap();
        }
    });
    rx
}

fn frame(body: &[u8]) -> Vec<u8> {
    let mut out = (body.len() as u32).to_ne_bytes().to_vec();
    out.extend_from_slice(body);
    out
}

/// Runs the helper with `args`, writes `input` to stdin and returns its one reply.
fn run(socket: &Path, args: &[&str], input: &[u8]) -> String {
    let mut child = Command::new(env!("CARGO_BIN_EXE_bridgey-browser-host"))
        .args(args)
        .env("BRIDGEY_BROWSER_SOCKET", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let mut out = Vec::new();
    child.stdout.take().unwrap().read_to_end(&mut out).unwrap();
    child.wait().unwrap();
    assert!(out.len() >= 4, "no reply");
    let length = u32::from_ne_bytes(out[..4].try_into().unwrap()) as usize;
    assert_eq!(out.len(), 4 + length, "exactly one frame");
    String::from_utf8(out[4..].to_vec()).unwrap()
}

#[test]
fn devices_and_sends_go_through_the_app() {
    let folder = Folder::new("ok");
    let socket = folder.0.join("browser.sock");
    let app = fake_app(
        &socket,
        r#"{"version":1,"ok":true,"devices":[{"id":"d1","name":"Pixel 8","platform":"android","connected":true,"links":true,"calls":true,"secret":"x"}]}"#,
    );
    let reply = run(&socket, &[CHROME], &frame(br#"{"v":1,"type":"devices"}"#));
    assert_eq!(reply, r#"{"devices":[{"calls":true,"connected":true,"id":"d1","links":true,"name":"Pixel 8","platform":"android"}],"ok":true,"v":1}"#);
    assert_eq!(app.recv_timeout(Duration::from_secs(5)).unwrap(), "{\"type\":\"devices\",\"version\":1}\n");
}

#[test]
fn firefox_callers_are_recognised() {
    let folder = Folder::new("firefox");
    let socket = folder.0.join("browser.sock");
    let app = fake_app(&socket, r#"{"version":1,"ok":true,"result":"waiting"}"#);
    let manifest = "/home/a/.mozilla/native-messaging-hosts/in.roundrobin.bridgey.json";
    let reply = run(&socket, &[manifest, "bridgey@roundrobin.in"], &frame(br#"{"v":1,"type":"send","device":"d1","url":"https://example.com/"}"#));
    assert_eq!(reply, r#"{"ok":true,"result":"waiting","v":1}"#);
    assert_eq!(app.recv_timeout(Duration::from_secs(5)).unwrap(), "{\"device\":\"d1\",\"type\":\"send\",\"url\":\"https://example.com/\",\"version\":1}\n");
}

#[test]
fn unknown_extensions_are_refused_before_the_app() {
    let folder = Folder::new("stranger");
    let socket = folder.0.join("browser.sock");
    let app = fake_app(&socket, r#"{"version":1,"ok":true,"devices":[]}"#);
    let body = frame(br#"{"v":1,"type":"devices"}"#);
    assert_eq!(run(&socket, &["chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/"], &body), r#"{"error":"forbidden","ok":false,"v":1}"#);
    assert_eq!(run(&socket, &["manifest.json", "other@example.com"], &body), r#"{"error":"forbidden","ok":false,"v":1}"#);
    assert_eq!(run(&socket, &[], &body), r#"{"error":"forbidden","ok":false,"v":1}"#);
    assert!(app.recv_timeout(Duration::from_millis(300)).is_err(), "the app heard nothing");
}

#[test]
fn bad_messages_are_refused_before_the_app() {
    let folder = Folder::new("bad");
    let socket = folder.0.join("browser.sock");
    let app = fake_app(&socket, r#"{"version":1,"ok":true,"result":"opened"}"#);
    let too_big = (64 * 1024u32).to_ne_bytes();
    assert_eq!(run(&socket, &[CHROME], &too_big), r#"{"error":"too_large","ok":false,"v":1}"#);
    assert_eq!(run(&socket, &[CHROME], &frame(br#"{"v":1,"type":"send","device":"d1","url":"file:///etc/passwd"}"#)), r#"{"error":"bad_url","ok":false,"v":1}"#);
    assert_eq!(run(&socket, &[CHROME], &frame(b"{not json")), r#"{"error":"bad_request","ok":false,"v":1}"#);
    assert_eq!(run(&socket, &[CHROME], &[3, 0]), r#"{"error":"bad_request","ok":false,"v":1}"#);
    assert!(app.recv_timeout(Duration::from_millis(300)).is_err(), "the app heard nothing");
}

#[test]
fn a_missing_or_unsafe_app_socket_is_reported() {
    let folder = Folder::new("unsafe");
    let socket = folder.0.join("browser.sock");
    let body = frame(br#"{"v":1,"type":"devices"}"#);
    assert_eq!(run(&socket, &[CHROME], &body), r#"{"error":"app_not_running","ok":false,"v":1}"#);
    let app = fake_app(&socket, r#"{"version":1,"ok":true,"devices":[]}"#);
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o666)).unwrap();
    assert_eq!(run(&socket, &[CHROME], &body), r#"{"error":"unsafe_endpoint","ok":false,"v":1}"#);
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::set_permissions(&folder.0, std::fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(run(&socket, &[CHROME], &body), r#"{"error":"unsafe_endpoint","ok":false,"v":1}"#);
    std::fs::set_permissions(&folder.0, std::fs::Permissions::from_mode(0o700)).unwrap();
    // A symlink to the real socket is refused too.
    let link = folder.0.join("link.sock");
    std::os::unix::fs::symlink(&socket, &link).unwrap();
    assert_eq!(run(&link, &[CHROME], &body), r#"{"error":"unsafe_endpoint","ok":false,"v":1}"#);
    assert!(app.recv_timeout(Duration::from_millis(300)).is_err(), "the app heard nothing");
    assert_eq!(run(&socket, &[CHROME], &body), r#"{"devices":[],"ok":true,"v":1}"#);
    // A relative override is ignored, not resolved.
    assert_eq!(run(Path::new("browser.sock"), &[CHROME], &body), r#"{"error":"app_not_running","ok":false,"v":1}"#);
}
