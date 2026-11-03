//! The agent socket: newline JSON both ways. A request is one object (`cmd` and its arguments); the daemon
//! answers with event lines (`{"event": ...}`) and ends with `{"result": ...}` or `{"error": ...}`. A client
//! may send more lines while it waits (the code confirmation in `bridgey pair`).

use serde_json::Value;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{UnixListener, UnixStream};

const MAX_LINE: usize = 256 * 1024;

pub fn listen(path: &Path) -> std::io::Result<UnixListener> {
    // Created 0600 from the start: the umask covers the window before the chmod.
    let old = unsafe { libc::umask(0o177) };
    let listener = UnixListener::bind(path);
    unsafe { libc::umask(old) };
    let listener = listener?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// Only this Unix user may use the daemon (SO_PEERCRED on Linux, getpeereid on macOS).
pub fn same_user(stream: &UnixStream) -> bool {
    match stream.peer_cred() {
        Ok(cred) => cred.uid() == unsafe { libc::getuid() },
        Err(_) => false,
    }
}

pub struct Conn {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
}

impl Conn {
    pub fn new(stream: UnixStream) -> Conn {
        let (r, w) = stream.into_split();
        Conn { reader: BufReader::new(r), writer: w }
    }

    pub async fn connect(path: &Path) -> std::io::Result<Conn> {
        Ok(Conn::new(UnixStream::connect(path).await?))
    }

    pub async fn send(&mut self, v: &Value) -> std::io::Result<()> {
        let mut line = v.to_string();
        line.push('\n');
        self.writer.write_all(line.as_bytes()).await
    }

    /// The next line as JSON; None at the end of the stream or on a bad line.
    pub async fn recv(&mut self) -> Option<Value> {
        let mut line = String::new();
        let mut limited = (&mut self.reader).take(MAX_LINE as u64);
        match limited.read_line(&mut line).await {
            Ok(0) | Err(_) => None,
            Ok(_) => serde_json::from_str(line.trim_end()).ok(),
        }
    }

    pub fn split(self) -> (BufReader<OwnedReadHalf>, OwnedWriteHalf) {
        (self.reader, self.writer)
    }
}

use tokio::io::AsyncReadExt;
