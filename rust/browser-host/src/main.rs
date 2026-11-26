//! `bridgey-browser-host`: started by the browser for each message from Bridgey's extension. See lib.rs and
//! docs/browser-extensions.md. It takes no options of its own: the browser passes the caller (Chromium:
//! `chrome-extension://<id>/`; Firefox: the host manifest's path and the add-on ID).

use bridgey_browser_host::{caller_from_args, handle, read_frame, write_frame, Allowlist, ErrorCode, Reply, MAX_REQUEST};
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

/// The app waits up to 8 seconds for a device's answer (docs/protocol.md); this leaves room for that.
const DEADLINE: Duration = Duration::from_secs(20);

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let caller = caller_from_args(&args);
    let allowlist = Allowlist::built_in();
    // One answer only: whichever comes first, the real one or the watchdog's.
    let answered = Arc::new(Mutex::new(false));
    let reply = |reply: &Reply, answered: &Mutex<bool>| {
        let mut done = answered.lock().unwrap_or_else(|e| e.into_inner());
        if !*done {
            *done = true;
            let stdout = io::stdout();
            let mut out = stdout.lock();
            let _ = write_frame(&mut out, &reply.to_json());
            let _ = out.flush();
        }
    };
    {
        let answered = answered.clone();
        std::thread::spawn(move || {
            std::thread::sleep(DEADLINE);
            reply(&Reply::Error(ErrorCode::NoAnswer), &answered);
            std::process::exit(1);
        });
    }
    let message = read_frame(&mut io::stdin().lock(), MAX_REQUEST);
    let mut ask_app = |line: &[u8]| ask(line);
    let answer = handle(caller.as_ref(), &allowlist, message, &mut ask_app);
    reply(&answer, &answered);
    std::process::exit(if matches!(answer, Reply::Error(_)) { 1 } else { 0 });
}

#[cfg(unix)]
fn ask(line: &[u8]) -> Result<Vec<u8>, bridgey_browser_host::TransportError> {
    unix::ask(line)
}

#[cfg(windows)]
fn ask(line: &[u8]) -> Result<Vec<u8>, bridgey_browser_host::TransportError> {
    windows::ask(line)
}
