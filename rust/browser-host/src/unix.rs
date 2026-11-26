//! macOS and Linux: the app's Unix socket, used only when it and its folder belong to this user and nobody else can
//! write to them, and only when the process at the other end runs as this user.

use bridgey_browser_host::{read_line, TransportError, MAX_REPLY};
use std::io::Write;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Tests and a separate profile point the helper at another socket. Only an absolute path is used.
const SOCKET_OVERRIDE: &str = "BRIDGEY_BROWSER_SOCKET";

pub fn ask(line: &[u8]) -> Result<Vec<u8>, TransportError> {
    let path = socket_path().ok_or(TransportError::NotRunning)?;
    check_owner(&path)?;
    let mut stream = UnixStream::connect(&path).map_err(|_| TransportError::NotRunning)?;
    if peer_uid(&stream) != Some(uid()) {
        return Err(TransportError::Unsafe);
    }
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));
    stream.write_all(line).map_err(|_| TransportError::NoAnswer)?;
    read_line(&mut stream, MAX_REPLY)
}

fn uid() -> libc::uid_t {
    // SAFETY: getuid has no preconditions and cannot fail.
    unsafe { libc::getuid() }
}

fn socket_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(SOCKET_OVERRIDE).map(PathBuf::from) {
        return path.is_absolute().then_some(path);
    }
    default_path()
}

/// The app's socket: `~/Library/Application Support/<bundle ID>/browser.sock`, for the app this helper sits in.
#[cfg(target_os = "macos")]
fn default_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    // <app>/Contents/Helpers/bridgey-browser-host -> <app>/Contents/Info.plist
    let contents = exe.parent()?.parent()?;
    let plist = std::fs::read_to_string(contents.join("Info.plist")).ok()?;
    let id = bridgey_browser_host::bundle_identifier(&plist)?;
    Some(home()?.join("Library/Application Support").join(id).join("browser.sock"))
}

/// A future Linux app (designed, not built): `$XDG_RUNTIME_DIR/bridgey/browser.sock`.
#[cfg(not(target_os = "macos"))]
fn default_path() -> Option<PathBuf> {
    let runtime = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?);
    runtime.is_absolute().then(|| runtime.join("bridgey/browser.sock"))
}

#[cfg(target_os = "macos")]
fn home() -> Option<PathBuf> {
    use std::ffi::CStr;
    let mut buffer = vec![0 as libc::c_char; 4096];
    // SAFETY: passwd is plain data; getpwuid_r writes into it and into the buffer we own, and sets result.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    let status = unsafe { libc::getpwuid_r(uid(), &mut entry, buffer.as_mut_ptr(), buffer.len(), &mut result) };
    if status != 0 || result.is_null() || entry.pw_dir.is_null() {
        return std::env::var_os("HOME").map(PathBuf::from);
    }
    // SAFETY: pw_dir points into the buffer and is NUL-terminated.
    let dir = unsafe { CStr::from_ptr(entry.pw_dir) };
    Some(PathBuf::from(std::ffi::OsStr::new(std::str::from_utf8(dir.to_bytes()).ok()?)))
}

/// The socket and its folder belong to this user; the socket is not a symlink and only the owner may use it; nobody
/// else may write to the folder.
fn check_owner(path: &Path) -> Result<(), TransportError> {
    let socket = std::fs::symlink_metadata(path).map_err(|_| TransportError::NotRunning)?;
    let folder = std::fs::symlink_metadata(path.parent().ok_or(TransportError::NotRunning)?).map_err(|_| TransportError::NotRunning)?;
    let me = uid();
    let socket_ok = socket.file_type().is_socket() && socket.uid() == me && socket.mode() & 0o077 == 0;
    let folder_ok = folder.is_dir() && folder.uid() == me && folder.mode() & 0o022 == 0;
    if socket_ok && folder_ok {
        Ok(())
    } else {
        Err(TransportError::Unsafe)
    }
}

#[cfg(any(target_os = "macos", target_os = "freebsd", target_os = "openbsd", target_os = "netbsd"))]
fn peer_uid(stream: &UnixStream) -> Option<libc::uid_t> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: the descriptor is a connected Unix socket owned by `stream`; both out pointers are valid.
    let status = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    (status == 0).then_some(uid)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_uid(stream: &UnixStream) -> Option<libc::uid_t> {
    let mut credentials = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: SO_PEERCRED fills a ucred of the given size on a connected Unix socket.
    let status = unsafe {
        libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, (&mut credentials as *mut libc::ucred).cast(), &mut length)
    };
    (status == 0).then_some(credentials.uid)
}
