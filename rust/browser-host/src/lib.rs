//! The native messaging helper between Bridgey's browser extension and the Bridgey app (docs/browser-extensions.md).
//!
//! A browser starts `bridgey-browser-host` for each message the extension sends with `runtime.sendNativeMessage`. The
//! helper reads one length-prefixed JSON message from stdin, checks who is calling and what they ask, passes a
//! checked request to the running app over a private local channel (a Unix socket on macOS and Linux, a named pipe on
//! Windows), and writes the app's checked answer back. Only two requests exist: the list of devices, and sending one
//! address (http, https, mailto or tel) to one device. Nothing is stored and nothing goes to the network.
//!
//! Everything here is pure and tested on any platform; `main.rs` wires it to stdio and the platform channel.

use serde::{Deserialize, Deserializer, Serialize};
use std::io::{self, Read, Write};

/// The native messaging host name, as in the host manifests and `runtime.sendNativeMessage`.
pub const HOST_NAME: &str = "in.roundrobin.bridgey";
/// The largest message accepted from the browser: one address of at most 4,096 bytes plus a device ID and keys.
pub const MAX_REQUEST: usize = 8 * 1024;
/// The largest answer accepted from the app and the largest written to the browser (browsers allow 1 MB).
pub const MAX_REPLY: usize = 64 * 1024;
/// Addresses are at most 4,096 UTF-8 bytes, like links between devices (docs/protocol.md, Quick actions).
pub const MAX_URL: usize = 4096;
/// At most this many devices go to the browser.
pub const MAX_DEVICES: usize = 32;

/// The extension IDs the helper answers, from extensions/browser/native-host.json (the same list the apps write into
/// the host manifests). A manifest naming another extension still reaches nothing: the helper checks the caller too.
const NATIVE_HOST_JSON: &str = include_str!("../../../extensions/browser/native-host.json");

/// Why a request was refused or could not be answered. The strings are what the extension shows a message for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    /// The caller is not one of Bridgey's extensions.
    Forbidden,
    /// Not a well-formed request.
    BadRequest,
    /// The message was larger than [`MAX_REQUEST`].
    TooLarge,
    /// The address is not an http, https, mailto or tel address Bridgey can send.
    BadUrl,
    /// Bridgey is not running, or browser support is off in it.
    AppNotRunning,
    /// The app's channel has the wrong owner or permissions, so the helper did not use it.
    UnsafeEndpoint,
    /// The app did not answer in time.
    NoAnswer,
    /// From the app: no paired device has this ID.
    UnknownDevice,
    /// From the app: the device is not connected.
    NotConnected,
    /// From the app: Links is off on this computer or on the device.
    LinksOff,
    /// From the app: calls are off, or the device cannot place calls.
    CallsOff,
    /// From the app: a send to this device is still waiting for its answer.
    Busy,
    /// From the app: the device declined (for example a link is already waiting there).
    Declined,
    /// From the app: too many sends in a short time.
    RateLimited,
    /// From the app: this kind of address cannot go to this device.
    Unsupported,
    /// From the app: anything else.
    Failed,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::Forbidden => "forbidden",
            ErrorCode::BadRequest => "bad_request",
            ErrorCode::TooLarge => "too_large",
            ErrorCode::BadUrl => "bad_url",
            ErrorCode::AppNotRunning => "app_not_running",
            ErrorCode::UnsafeEndpoint => "unsafe_endpoint",
            ErrorCode::NoAnswer => "no_answer",
            ErrorCode::UnknownDevice => "unknown_device",
            ErrorCode::NotConnected => "not_connected",
            ErrorCode::LinksOff => "links_off",
            ErrorCode::CallsOff => "calls_off",
            ErrorCode::Busy => "busy",
            ErrorCode::Declined => "declined",
            ErrorCode::RateLimited => "rate_limited",
            ErrorCode::Unsupported => "unsupported",
            ErrorCode::Failed => "failed",
        }
    }

    /// The codes an app may answer with; anything else becomes `failed`.
    fn from_app(code: &str) -> ErrorCode {
        match code {
            "unknown_device" => ErrorCode::UnknownDevice,
            "not_connected" => ErrorCode::NotConnected,
            "links_off" => ErrorCode::LinksOff,
            "calls_off" => ErrorCode::CallsOff,
            "busy" => ErrorCode::Busy,
            "declined" => ErrorCode::Declined,
            "rate_limited" => ErrorCode::RateLimited,
            "unsupported" => ErrorCode::Unsupported,
            "bad_url" => ErrorCode::BadUrl,
            "no_answer" => ErrorCode::NoAnswer,
            _ => ErrorCode::Failed,
        }
    }
}

// ---------------------------------------------------------------- framing

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    /// stdin closed before a whole message arrived.
    Closed,
    /// The length prefix is larger than the limit; the body was not read.
    TooLarge(u32),
}

/// Reads one native messaging frame: a 32-bit length in native byte order, then that many bytes of UTF-8 JSON.
pub fn read_frame<R: Read>(reader: &mut R, limit: usize) -> Result<Vec<u8>, FrameError> {
    let mut prefix = [0u8; 4];
    reader.read_exact(&mut prefix).map_err(|_| FrameError::Closed)?;
    let length = u32::from_ne_bytes(prefix);
    if length as usize > limit {
        return Err(FrameError::TooLarge(length));
    }
    let mut body = vec![0u8; length as usize];
    reader.read_exact(&mut body).map_err(|_| FrameError::Closed)?;
    Ok(body)
}

/// Writes one native messaging frame.
pub fn write_frame<W: Write>(writer: &mut W, body: &[u8]) -> io::Result<()> {
    let length = u32::try_from(body.len()).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "frame too large"))?;
    writer.write_all(&length.to_ne_bytes())?;
    writer.write_all(body)?;
    writer.flush()
}

// ---------------------------------------------------------------- the caller

/// Who started the helper, from the arguments the browser passes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Caller {
    /// Chrome, Edge, Brave, Arc and other Chromium browsers: `chrome-extension://<id>/` (Windows adds
    /// `--parent-window=<n>`).
    Chromium(String),
    /// Firefox: the host manifest's path, then the add-on ID.
    Firefox(String),
}

/// Reads the caller from the helper's arguments (`args[0]` is the program).
pub fn caller_from_args(args: &[String]) -> Option<Caller> {
    for arg in args.iter().skip(1) {
        if let Some(rest) = arg.strip_prefix("chrome-extension://") {
            let id = rest.strip_suffix('/').unwrap_or(rest);
            return (id.len() == 32 && id.bytes().all(|b| (b'a'..=b'p').contains(&b))).then(|| Caller::Chromium(id.to_string()));
        }
    }
    // Firefox: <path to the host manifest> <add-on ID>. Add-on IDs are an email-like name or a {GUID}.
    if args.len() == 3 && !args[1].starts_with("--") {
        let id = &args[2];
        let ok = !id.is_empty()
            && id.len() <= 80
            && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"@.-_{}".contains(&b));
        if ok {
            return Some(Caller::Firefox(id.clone()));
        }
    }
    None
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeHostFile {
    name: String,
    chromium_extension_ids: Vec<String>,
    firefox_extension_ids: Vec<String>,
}

/// The extensions that may use the helper.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Allowlist {
    pub chromium: Vec<String>,
    pub firefox: Vec<String>,
}

impl Allowlist {
    /// The list built into this helper (extensions/browser/native-host.json).
    pub fn built_in() -> Allowlist {
        Allowlist::parse(NATIVE_HOST_JSON).expect("extensions/browser/native-host.json is valid")
    }

    pub fn parse(text: &str) -> Option<Allowlist> {
        let file: NativeHostFile = serde_json::from_str(text).ok()?;
        (file.name == HOST_NAME).then_some(Allowlist { chromium: file.chromium_extension_ids, firefox: file.firefox_extension_ids })
    }

    pub fn allows(&self, caller: &Caller) -> bool {
        match caller {
            Caller::Chromium(id) => self.chromium.iter().any(|allowed| allowed == id),
            Caller::Firefox(id) => self.firefox.iter().any(|allowed| allowed == id),
        }
    }
}

// ---------------------------------------------------------------- requests from the browser

/// A checked request from the extension.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    Devices,
    Send { device: String, url: String },
}

/// A present value must be a string: `null` and other types are refused.
fn present_string<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<String>, D::Error> {
    String::deserialize(deserializer).map(Some)
}

/// The message as the extension writes it. Unknown keys, repeated keys and wrong types are refused.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRequest {
    v: u64,
    #[serde(rename = "type")]
    kind: String,
    #[serde(default, deserialize_with = "present_string")]
    device: Option<String>,
    #[serde(default, deserialize_with = "present_string")]
    url: Option<String>,
}

/// Device IDs are random UUIDs; this accepts any short ASCII letters, digits and hyphens.
pub fn valid_device_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

pub fn parse_request(body: &[u8]) -> Result<Request, ErrorCode> {
    let raw: RawRequest = serde_json::from_slice(body).map_err(|_| ErrorCode::BadRequest)?;
    if raw.v != 1 {
        return Err(ErrorCode::BadRequest);
    }
    match (raw.kind.as_str(), raw.device, raw.url) {
        ("devices", None, None) => Ok(Request::Devices),
        ("send", Some(device), Some(url)) => {
            if !valid_device_id(&device) {
                return Err(ErrorCode::BadRequest);
            }
            let url = validate_url(&url).ok_or(ErrorCode::BadUrl)?;
            Ok(Request::Send { device, url })
        }
        _ => Err(ErrorCode::BadRequest),
    }
}

// ---------------------------------------------------------------- addresses

/// What kind of address a checked URL is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UrlKind {
    Web,
    Mailto,
    Tel,
}

pub fn url_kind(url: &str) -> Option<UrlKind> {
    let scheme = url.split_once(':')?.0.to_ascii_lowercase();
    match scheme.as_str() {
        "http" | "https" => Some(UrlKind::Web),
        "mailto" => Some(UrlKind::Mailto),
        "tel" => Some(UrlKind::Tel),
        _ => None,
    }
}

/// Checks an address and returns the form passed to the app, or None.
///
/// - http and https: the rules every Bridgey device applies to links (docs/protocol.md): a host, no user name or
///   password, a valid port, no spaces, control characters or backslashes. The scheme is written in lower case.
/// - mailto: one or more addresses with an `@`, optional `?` fields; printable ASCII only.
/// - tel: 3 to 15 digits with an optional leading `+`; spaces (`%20`), dots, hyphens and brackets are dropped,
///   `;` parameters are dropped. Written as `tel:+4420...`.
///
/// Browsers already give addresses in ASCII (punycode hosts, percent-encoded paths); anything else is refused.
pub fn validate_url(value: &str) -> Option<String> {
    if value.is_empty() || value.len() > MAX_URL || !value.bytes().all(|b| (0x21..=0x7e).contains(&b)) || value.contains('\\') {
        return None;
    }
    let (scheme, rest) = value.split_once(':')?;
    match scheme.to_ascii_lowercase().as_str() {
        scheme @ ("http" | "https") => web(scheme, rest),
        "mailto" => mailto(rest),
        "tel" => tel(rest),
        _ => None,
    }
}

fn web(scheme: &str, rest: &str) -> Option<String> {
    let after = rest.strip_prefix("//")?;
    let authority = after.split(['/', '?', '#']).next().unwrap_or("");
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let (host, port) = if let Some(v6) = authority.strip_prefix('[') {
        let (inside, tail) = v6.split_once(']')?;
        if inside.is_empty() || !inside.bytes().all(|b| b.is_ascii_hexdigit() || b == b':' || b == b'.') {
            return None;
        }
        (inside, if tail.is_empty() { None } else { Some(tail.strip_prefix(':')?) })
    } else {
        match authority.rsplit_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (authority, None),
        }
    };
    if host.is_empty() || (!authority.starts_with('[') && !host.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))) {
        return None;
    }
    if let Some(p) = port {
        let ok = !p.is_empty() && p.len() <= 5 && p.bytes().all(|b| b.is_ascii_digit()) && p.parse::<u32>().is_ok_and(|n| (1..=65_535).contains(&n));
        if !ok {
            return None;
        }
    }
    Some(format!("{scheme}:{rest}"))
}

fn mailto(rest: &str) -> Option<String> {
    let addresses = rest.split('?').next().unwrap_or("");
    if addresses.is_empty() {
        return None;
    }
    let decoded = percent_decode(addresses)?;
    let all_ok = decoded.split(',').all(|address| {
        let address = address.trim();
        match address.split_once('@') {
            Some((local, domain)) => {
                !local.is_empty()
                    && !domain.is_empty()
                    && !domain.contains('@')
                    && address.bytes().all(|b| (0x21..=0x7e).contains(&b) && !b"<>\"(),;:[]\\".contains(&b))
            }
            None => false,
        }
    });
    all_ok.then(|| format!("mailto:{rest}"))
}

fn tel(rest: &str) -> Option<String> {
    let number = rest.strip_prefix("//").unwrap_or(rest);
    let number = number.split(';').next().unwrap_or("");
    let decoded = percent_decode(number)?;
    if !decoded.chars().all(|c| c.is_ascii_digit() || "+-(). ".contains(c)) {
        return None;
    }
    let plus = decoded.matches('+').count();
    if plus > 1 || (plus == 1 && !decoded.trim_start().starts_with('+')) {
        return None;
    }
    let digits: String = decoded.chars().filter(|c| c.is_ascii_digit()).collect();
    if !(3..=15).contains(&digits.len()) {
        return None;
    }
    Some(format!("tel:{}{digits}", if plus == 1 { "+" } else { "" }))
}

/// Decodes %XX escapes to ASCII; non-ASCII results and broken escapes are refused.
fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = String::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = value.get(i + 1..i + 3)?;
            let byte = u8::from_str_radix(hex, 16).ok()?;
            if !(0x20..=0x7e).contains(&byte) {
                return None;
            }
            out.push(byte as char);
            i += 3;
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    Some(out)
}

// ---------------------------------------------------------------- the app

/// The line sent to the app for a checked request (newline-terminated JSON).
pub fn app_request(request: &Request) -> Vec<u8> {
    let value = match request {
        Request::Devices => serde_json::json!({"version": 1, "type": "devices"}),
        Request::Send { device, url } => serde_json::json!({"version": 1, "type": "send", "device": device, "url": url}),
    };
    let mut line = serde_json::to_vec(&value).expect("JSON");
    line.push(b'\n');
    line
}

/// A device as the browser sees it: no addresses, battery or anything else.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    /// `android`, `macos`, `windows`, `ios`, `linux`, or empty when unknown.
    pub platform: String,
    pub connected: bool,
    /// Links is on at both ends.
    pub links: bool,
    /// The device places calls for this computer (tel: addresses).
    pub calls: bool,
}

/// What a send did on the device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendResult {
    /// The device opened the page.
    Opened,
    /// The device keeps it for the person to open.
    Waiting,
    /// The phone was asked to place the call.
    Calling,
    /// This computer asks first (Settings > Calls), then calls.
    Asking,
    /// The email address was copied on the device.
    Copied,
}

impl SendResult {
    pub fn as_str(self) -> &'static str {
        match self {
            SendResult::Opened => "opened",
            SendResult::Waiting => "waiting",
            SendResult::Calling => "calling",
            SendResult::Asking => "asking",
            SendResult::Copied => "copied",
        }
    }

    fn parse(value: &str) -> Option<SendResult> {
        Some(match value {
            "opened" => SendResult::Opened,
            "waiting" => SendResult::Waiting,
            "calling" => SendResult::Calling,
            "asking" => SendResult::Asking,
            "copied" => SendResult::Copied,
            _ => return None,
        })
    }
}

/// The answer written to the browser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
    Devices(Vec<Device>),
    Sent(SendResult),
    Error(ErrorCode),
}

impl Reply {
    pub fn to_json(&self) -> Vec<u8> {
        let value = match self {
            Reply::Devices(devices) => serde_json::json!({"v": 1, "ok": true, "devices": devices}),
            Reply::Sent(result) => serde_json::json!({"v": 1, "ok": true, "result": result.as_str()}),
            Reply::Error(code) => serde_json::json!({"v": 1, "ok": false, "error": code.as_str()}),
        };
        serde_json::to_vec(&value).expect("JSON")
    }
}

const PLATFORMS: [&str; 6] = ["android", "macos", "windows", "ios", "linux", "cli"];

/// Reads the app's answer to `request`. Only the fields above are kept; names are cut to 64 characters; anything
/// malformed becomes `failed`.
pub fn parse_app_reply(line: &[u8], request: &Request) -> Reply {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(line) else { return Reply::Error(ErrorCode::Failed) };
    let Some(object) = value.as_object() else { return Reply::Error(ErrorCode::Failed) };
    if object.get("version").and_then(|v| v.as_u64()) != Some(1) {
        return Reply::Error(ErrorCode::Failed);
    }
    match object.get("ok").and_then(|v| v.as_bool()) {
        Some(false) => return Reply::Error(ErrorCode::from_app(object.get("error").and_then(|v| v.as_str()).unwrap_or(""))),
        Some(true) => {}
        None => return Reply::Error(ErrorCode::Failed),
    }
    match request {
        Request::Devices => {
            let Some(list) = object.get("devices").and_then(|v| v.as_array()) else { return Reply::Error(ErrorCode::Failed) };
            let mut devices = Vec::new();
            for item in list.iter().take(MAX_DEVICES) {
                let text = |key: &str| item.get(key).and_then(|v| v.as_str());
                let flag = |key: &str| item.get(key).and_then(|v| v.as_bool()).unwrap_or(false);
                let (Some(id), Some(name)) = (text("id"), text("name")) else { continue };
                if !valid_device_id(id) {
                    continue;
                }
                let name: String = name.chars().filter(|c| !c.is_control()).take(64).collect();
                let platform = text("platform").filter(|p| PLATFORMS.contains(p)).unwrap_or("").to_string();
                devices.push(Device { id: id.to_string(), name, platform, connected: flag("connected"), links: flag("links"), calls: flag("calls") });
            }
            Reply::Devices(devices)
        }
        Request::Send { .. } => match object.get("result").and_then(|v| v.as_str()).and_then(SendResult::parse) {
            Some(result) => Reply::Sent(result),
            None => Reply::Error(ErrorCode::Failed),
        },
    }
}

/// How the app's channel failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportError {
    /// Nothing listens: Bridgey is not running or browser support is off.
    NotRunning,
    /// The channel exists but its owner or permissions are wrong.
    Unsafe,
    /// No answer in time, or the connection broke.
    NoAnswer,
}

/// Sends one request line to the app and returns its answer line.
pub type AskApp<'a> = dyn FnMut(&[u8]) -> Result<Vec<u8>, TransportError> + 'a;

/// The whole decision for one message: who calls, what they ask, the app's answer. `ask_app` sends one request line
/// and returns the answer line.
pub fn handle(
    caller: Option<&Caller>,
    allowlist: &Allowlist,
    message: Result<Vec<u8>, FrameError>,
    ask_app: &mut AskApp,
) -> Reply {
    if !caller.is_some_and(|c| allowlist.allows(c)) {
        return Reply::Error(ErrorCode::Forbidden);
    }
    let body = match message {
        Ok(body) => body,
        Err(FrameError::TooLarge(_)) => return Reply::Error(ErrorCode::TooLarge),
        Err(FrameError::Closed) => return Reply::Error(ErrorCode::BadRequest),
    };
    let request = match parse_request(&body) {
        Ok(request) => request,
        Err(code) => return Reply::Error(code),
    };
    match ask_app(&app_request(&request)) {
        Ok(line) if line.len() <= MAX_REPLY => parse_app_reply(&line, &request),
        Ok(_) => Reply::Error(ErrorCode::Failed),
        Err(TransportError::NotRunning) => Reply::Error(ErrorCode::AppNotRunning),
        Err(TransportError::Unsafe) => Reply::Error(ErrorCode::UnsafeEndpoint),
        Err(TransportError::NoAnswer) => Reply::Error(ErrorCode::NoAnswer),
    }
}

/// Reads one newline-terminated line of at most `limit` bytes (without the newline).
pub fn read_line<R: Read>(reader: &mut R, limit: usize) -> Result<Vec<u8>, TransportError> {
    let mut line = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let count = reader.read(&mut chunk).map_err(|_| TransportError::NoAnswer)?;
        if count == 0 {
            return Err(TransportError::NoAnswer);
        }
        if let Some(end) = chunk[..count].iter().position(|&b| b == b'\n') {
            line.extend_from_slice(&chunk[..end]);
            return if line.len() <= limit { Ok(line) } else { Err(TransportError::NoAnswer) };
        }
        line.extend_from_slice(&chunk[..count]);
        if line.len() > limit {
            return Err(TransportError::NoAnswer);
        }
    }
}

// ---------------------------------------------------------------- where the app listens

/// The macOS app's bundle identifier, read from the Info.plist of the app the helper sits in
/// (`<app>/Contents/Helpers/bridgey-browser-host` reads `<app>/Contents/Info.plist`). Only Bridgey's own identifiers
/// are accepted, so a copied helper never talks to another app. A test instance's helper finds its own instance.
pub fn bundle_identifier(info_plist: &str) -> Option<String> {
    let after = info_plist.split("<key>CFBundleIdentifier</key>").nth(1)?;
    let start = after.find("<string>")? + "<string>".len();
    let end = after[start..].find("</string>")? + start;
    let id = after[start..end].trim();
    let ok = (id == HOST_NAME || id.starts_with("in.roundrobin.bridgey."))
        && id.len() <= 96
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
    ok.then(|| id.to_string())
}

/// The Windows named pipe for a user: `\\.\pipe\in.roundrobin.bridgey.browser.<SID>`.
pub fn pipe_name(user_sid: &str) -> Option<String> {
    let ok = user_sid.starts_with("S-1-") && user_sid.len() <= 184 && user_sid.bytes().all(|b| b.is_ascii_digit() || b == b'-' || b == b'S');
    ok.then(|| format!(r"\\.\pipe\{HOST_NAME}.browser.{user_sid}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALLOWED: &str = "aajelmcjgfjbhemgofnompobgbcdfcin";

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn frames_round_trip_in_native_byte_order() {
        let mut buffer = Vec::new();
        write_frame(&mut buffer, br#"{"v":1}"#).unwrap();
        assert_eq!(&buffer[..4], &7u32.to_ne_bytes());
        assert_eq!(read_frame(&mut buffer.as_slice(), MAX_REQUEST).unwrap(), br#"{"v":1}"#);
    }

    #[test]
    fn oversized_frames_are_refused_without_reading_them() {
        let mut buffer = (MAX_REQUEST as u32 + 1).to_ne_bytes().to_vec();
        buffer.extend(std::iter::repeat_n(b'x', 16));
        assert_eq!(read_frame(&mut buffer.as_slice(), MAX_REQUEST), Err(FrameError::TooLarge(MAX_REQUEST as u32 + 1)));
    }

    #[test]
    fn short_frames_are_closed() {
        let mut buffer = 10u32.to_ne_bytes().to_vec();
        buffer.extend_from_slice(b"abc");
        assert_eq!(read_frame(&mut buffer.as_slice(), MAX_REQUEST), Err(FrameError::Closed));
        assert_eq!(read_frame(&mut [1u8, 0].as_slice(), MAX_REQUEST), Err(FrameError::Closed));
    }

    #[test]
    fn callers_come_from_the_browser_arguments() {
        let chrome = format!("chrome-extension://{ALLOWED}/");
        assert_eq!(caller_from_args(&args(&["host", &chrome])), Some(Caller::Chromium(ALLOWED.into())));
        assert_eq!(caller_from_args(&args(&["host.exe", &chrome, "--parent-window=0"])), Some(Caller::Chromium(ALLOWED.into())));
        assert_eq!(
            caller_from_args(&args(&["host", "/Users/a/Library/Application Support/Mozilla/NativeMessagingHosts/in.roundrobin.bridgey.json", "bridgey@roundrobin.in"])),
            Some(Caller::Firefox("bridgey@roundrobin.in".into()))
        );
        assert_eq!(caller_from_args(&args(&["host"])), None);
        assert_eq!(caller_from_args(&args(&["host", "chrome-extension://short/"])), None);
        assert_eq!(caller_from_args(&args(&["host", "chrome-extension://AAJELMCJGFJBHEMGOFNOMPOBGBCDFCIN/"])), None);
        assert_eq!(caller_from_args(&args(&["host", "manifest.json", "bad id with spaces"])), None);
    }

    #[test]
    fn the_built_in_allow_list_matches_the_extension() {
        let list = Allowlist::built_in();
        assert!(list.allows(&Caller::Chromium(ALLOWED.into())));
        assert!(list.allows(&Caller::Firefox("bridgey@roundrobin.in".into())));
        assert!(!list.allows(&Caller::Chromium("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into())));
        assert!(!list.allows(&Caller::Firefox("other@example.com".into())));
        // A Firefox ID never passes as a Chromium one or the other way round.
        assert!(!list.allows(&Caller::Firefox(ALLOWED.into())));
    }

    #[test]
    fn requests_are_strict() {
        assert_eq!(parse_request(br#"{"v":1,"type":"devices"}"#), Ok(Request::Devices));
        assert_eq!(
            parse_request(br#"{"v":1,"type":"send","device":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0","url":"https://example.com/a?b=c#d"}"#),
            Ok(Request::Send { device: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0".into(), url: "https://example.com/a?b=c#d".into() })
        );
        for bad in [
            &br#"{"v":2,"type":"devices"}"#[..],
            br#"{"v":"1","type":"devices"}"#,
            br#"{"v":1.0,"type":"devices"}"#,
            br#"{"v":1,"type":"devices","extra":true}"#,
            br#"{"v":1,"type":"devices","device":"abc"}"#,
            br#"{"v":1,"type":"devices","url":null}"#,
            br#"{"v":1,"type":"send","device":"abc"}"#,
            br#"{"v":1,"type":"send","device":"abc","url":"https://a.b","url":"https://c.d"}"#,
            br#"{"v":1,"type":"send","device":"a b","url":"https://a.b"}"#,
            br#"{"v":1,"type":"send","device":5,"url":"https://a.b"}"#,
            br#"{"v":1,"type":"open","device":"abc","url":"https://a.b"}"#,
            br#"[1]"#,
            br#"{"v":1,"type":"devices"} trailing"#,
            b"",
        ] {
            assert_eq!(parse_request(bad), Err(ErrorCode::BadRequest), "{}", String::from_utf8_lossy(bad));
        }
        assert_eq!(parse_request(br#"{"v":1,"type":"send","device":"abc","url":"javascript:alert(1)"}"#), Err(ErrorCode::BadUrl));
    }

    #[test]
    fn web_addresses_follow_the_link_rules() {
        assert_eq!(validate_url("https://example.com").as_deref(), Some("https://example.com"));
        assert_eq!(validate_url("HTTPS://Example.com/Path").as_deref(), Some("https://Example.com/Path"));
        assert_eq!(validate_url("http://[::1]:8080/x").as_deref(), Some("http://[::1]:8080/x"));
        assert_eq!(validate_url("http://192.168.1.4:42458/").as_deref(), Some("http://192.168.1.4:42458/"));
        assert_eq!(validate_url("https://xn--bcher-kva.example/").as_deref(), Some("https://xn--bcher-kva.example/"));
        for bad in [
            "https://user:pass@example.com/",
            "https://user@example.com/",
            "https:///path",
            "https://",
            "https:example.com",
            "https://exa mple.com",
            "https://example.com/a b",
            "https://example.com\\@evil",
            "https://example.com:0/",
            "https://example.com:65536/",
            "https://example.com:/",
            "https://bücher.example/",
            "https://example.com/\u{7f}",
            "ftp://example.com/",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,hi",
            "chrome://settings",
            "about:blank",
            "",
        ] {
            assert_eq!(validate_url(bad), None, "{bad}");
        }
        let long = format!("https://example.com/{}", "a".repeat(MAX_URL));
        assert_eq!(validate_url(&long), None);
        let fits = format!("https://example.com/{}", "a".repeat(MAX_URL - 20));
        assert!(validate_url(&fits).is_some());
    }

    #[test]
    fn mailto_and_tel_addresses() {
        assert_eq!(validate_url("mailto:hello@roundrobin.in").as_deref(), Some("mailto:hello@roundrobin.in"));
        assert_eq!(validate_url("mailto:a@b.c,d@e.f?subject=Hi").as_deref(), Some("mailto:a@b.c,d@e.f?subject=Hi"));
        assert_eq!(validate_url("MAILTO:a%40b.c").as_deref(), Some("mailto:a%40b.c"));
        for bad in ["mailto:", "mailto:?subject=x", "mailto:nobody", "mailto:a@@b", "mailto:a@b%0Ac", "mailto:<a@b>"] {
            assert_eq!(validate_url(bad), None, "{bad}");
        }
        assert_eq!(validate_url("tel:+44%2020%207946%200958").as_deref(), Some("tel:+442079460958"));
        assert_eq!(validate_url("tel:(555)%20123-4567").as_deref(), Some("tel:5551234567"));
        assert_eq!(validate_url("tel:+1-555-123-4567;ext=12").as_deref(), Some("tel:+15551234567"));
        assert_eq!(validate_url("TEL:112").as_deref(), Some("tel:112"));
        for bad in ["tel:", "tel:12", "tel:1234567890123456", "tel:12+34", "tel:++123", "tel:abc123", "tel:%0A123", "tel:%zz123"] {
            assert_eq!(validate_url(bad), None, "{bad}");
        }
    }

    #[test]
    fn unknown_extensions_never_reach_the_app() {
        let asked = std::cell::Cell::new(0);
        let mut app = |_: &[u8]| -> Result<Vec<u8>, TransportError> {
            asked.set(asked.get() + 1);
            Ok(br#"{"version":1,"ok":true,"devices":[]}"#.to_vec())
        };
        let list = Allowlist::built_in();
        let stranger = Caller::Chromium("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into());
        let message = || Ok(br#"{"v":1,"type":"devices"}"#.to_vec());
        assert_eq!(handle(Some(&stranger), &list, message(), &mut app), Reply::Error(ErrorCode::Forbidden));
        assert_eq!(handle(None, &list, message(), &mut app), Reply::Error(ErrorCode::Forbidden));
        assert_eq!(asked.get(), 0);
        let friend = Caller::Chromium(ALLOWED.into());
        assert_eq!(handle(Some(&friend), &list, message(), &mut app), Reply::Devices(vec![]));
        assert_eq!(asked.get(), 1);
    }

    #[test]
    fn the_app_gets_only_checked_requests() {
        let list = Allowlist::built_in();
        let friend = Caller::Firefox("bridgey@roundrobin.in".into());
        let lines = std::cell::RefCell::new(Vec::new());
        let mut app = |line: &[u8]| -> Result<Vec<u8>, TransportError> {
            lines.borrow_mut().push(String::from_utf8(line.to_vec()).unwrap());
            Ok(br#"{"version":1,"ok":true,"result":"opened"}"#.to_vec())
        };
        let send = br#"{"v":1,"type":"send","device":"abc","url":"tel:+44 20"}"#.to_vec();
        assert_eq!(handle(Some(&friend), &list, Ok(send), &mut app), Reply::Error(ErrorCode::BadUrl));
        let send = br#"{"v":1,"type":"send","device":"abc","url":"tel:+44%2020%207946%200958"}"#.to_vec();
        assert_eq!(handle(Some(&friend), &list, Ok(send), &mut app), Reply::Sent(SendResult::Opened));
        assert_eq!(*lines.borrow(), vec!["{\"device\":\"abc\",\"type\":\"send\",\"url\":\"tel:+442079460958\",\"version\":1}\n".to_string()]);
        assert_eq!(handle(Some(&friend), &list, Err(FrameError::TooLarge(99_999)), &mut app), Reply::Error(ErrorCode::TooLarge));
    }

    #[test]
    fn app_failures_map_to_codes() {
        let list = Allowlist::built_in();
        let friend = Caller::Chromium(ALLOWED.into());
        for (error, code) in [(TransportError::NotRunning, ErrorCode::AppNotRunning), (TransportError::Unsafe, ErrorCode::UnsafeEndpoint), (TransportError::NoAnswer, ErrorCode::NoAnswer)] {
            let mut app = |_: &[u8]| -> Result<Vec<u8>, TransportError> { Err(error) };
            assert_eq!(handle(Some(&friend), &list, Ok(br#"{"v":1,"type":"devices"}"#.to_vec()), &mut app), Reply::Error(code));
        }
    }

    #[test]
    fn app_answers_are_reduced_to_known_fields() {
        let reply = parse_app_reply(
            br#"{"version":1,"ok":true,"devices":[
                {"id":"d1","name":"Pixel\u0007 8","platform":"android","connected":true,"links":true,"calls":true,"battery":80,"address":"10.0.0.2"},
                {"id":"bad id","name":"x"},
                {"id":"d2","name":"MacBook","platform":"toaster","connected":false}
            ]}"#,
            &Request::Devices,
        );
        assert_eq!(
            reply,
            Reply::Devices(vec![
                Device { id: "d1".into(), name: "Pixel 8".into(), platform: "android".into(), connected: true, links: true, calls: true },
                Device { id: "d2".into(), name: "MacBook".into(), platform: "".into(), connected: false, links: false, calls: false },
            ])
        );
        let json = String::from_utf8(reply.to_json()).unwrap();
        assert!(!json.contains("battery") && !json.contains("10.0.0.2"));
        let send = Request::Send { device: "d1".into(), url: "https://a.b".into() };
        assert_eq!(parse_app_reply(br#"{"version":1,"ok":true,"result":"waiting"}"#, &send), Reply::Sent(SendResult::Waiting));
        assert_eq!(parse_app_reply(br#"{"version":1,"ok":true,"result":"exploded"}"#, &send), Reply::Error(ErrorCode::Failed));
        assert_eq!(parse_app_reply(br#"{"version":1,"ok":false,"error":"links_off"}"#, &send), Reply::Error(ErrorCode::LinksOff));
        assert_eq!(parse_app_reply(br#"{"version":1,"ok":false,"error":"<script>"}"#, &send), Reply::Error(ErrorCode::Failed));
        assert_eq!(parse_app_reply(br#"{"version":2,"ok":true,"result":"opened"}"#, &send), Reply::Error(ErrorCode::Failed));
        assert_eq!(parse_app_reply(b"not json", &send), Reply::Error(ErrorCode::Failed));
        let many: Vec<String> = (0..40).map(|i| format!(r#"{{"id":"d{i}","name":"n"}}"#)).collect();
        let line = format!(r#"{{"version":1,"ok":true,"devices":[{}]}}"#, many.join(","));
        let Reply::Devices(list) = parse_app_reply(line.as_bytes(), &Request::Devices) else { panic!() };
        assert_eq!(list.len(), MAX_DEVICES);
    }

    #[test]
    fn replies_to_the_browser() {
        assert_eq!(Reply::Error(ErrorCode::Forbidden).to_json(), br#"{"error":"forbidden","ok":false,"v":1}"#);
        assert_eq!(Reply::Sent(SendResult::Copied).to_json(), br#"{"ok":true,"result":"copied","v":1}"#);
    }

    #[test]
    fn lines_are_bounded() {
        assert_eq!(read_line(&mut &b"{\"a\":1}\nrest"[..], 100).unwrap(), b"{\"a\":1}");
        assert_eq!(read_line(&mut &b"no newline"[..], 100), Err(TransportError::NoAnswer));
        let long = vec![b'a'; 300];
        assert_eq!(read_line(&mut long.as_slice(), 100), Err(TransportError::NoAnswer));
    }

    #[test]
    fn bundle_identifiers_and_pipe_names() {
        let plist = "<dict>\n\t<key>CFBundleExecutable</key>\n\t<string>BridgeyMac</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>in.roundrobin.bridgey</string>\n</dict>";
        assert_eq!(bundle_identifier(plist).as_deref(), Some("in.roundrobin.bridgey"));
        let test = plist.replace("in.roundrobin.bridgey<", "in.roundrobin.bridgey.test.browser<");
        assert_eq!(bundle_identifier(&test).as_deref(), Some("in.roundrobin.bridgey.test.browser"));
        assert_eq!(bundle_identifier(&plist.replace("in.roundrobin.bridgey<", "com.example.app<")), None);
        assert_eq!(bundle_identifier(&plist.replace("in.roundrobin.bridgey<", "in.roundrobin.bridgey/../x<")), None);
        assert_eq!(bundle_identifier("<dict></dict>"), None);
        assert_eq!(pipe_name("S-1-5-21-1-2-3-1001").as_deref(), Some(r"\\.\pipe\in.roundrobin.bridgey.browser.S-1-5-21-1-2-3-1001"));
        assert_eq!(pipe_name("S-1-5\\..\\x"), None);
        assert_eq!(pipe_name("user"), None);
    }
}
