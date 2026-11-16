//! The C ABI end to end, called the way a host app calls it: two clients pair and exchange clipboard text,
//! one keeping its identity through host storage callbacks; events and strings are freed by the library.

use bridgey_core::ffi::*;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::Mutex;
use std::time::{Duration, Instant};

static STORE: Mutex<Option<HashMap<String, Vec<u8>>>> = Mutex::new(None);

unsafe extern "C" fn load(_: *mut c_void, key: *const c_char, out: *mut BridgeyBuffer) -> i32 {
    let key = CStr::from_ptr(key).to_str().unwrap().to_string();
    match STORE.lock().unwrap().get_or_insert_with(HashMap::new).get(&key) {
        Some(v) => {
            assert_eq!(bridgey_buffer_set(out, v.as_ptr(), v.len()), BRIDGEY_OK);
            1
        }
        None => 0,
    }
}

unsafe extern "C" fn store(_: *mut c_void, key: *const c_char, data: *const u8, len: usize) -> i32 {
    let key = CStr::from_ptr(key).to_str().unwrap().to_string();
    STORE.lock().unwrap().get_or_insert_with(HashMap::new).insert(key, std::slice::from_raw_parts(data, len).to_vec());
    0
}

unsafe extern "C" fn remove(_: *mut c_void, key: *const c_char) -> i32 {
    let key = CStr::from_ptr(key).to_str().unwrap().to_string();
    STORE.lock().unwrap().get_or_insert_with(HashMap::new).remove(&key);
    0
}

fn s(b: &BridgeyStr) -> Option<String> {
    (!b.ptr.is_null()).then(|| String::from_utf8(unsafe { std::slice::from_raw_parts(b.ptr, b.len) }.to_vec()).unwrap())
}

struct Owned {
    kind: BridgeyEventKind,
    status: i32,
    id: u64,
    device_id: Option<String>,
    text: Option<String>,
}

fn start(name: &str, storage: Option<&BridgeyStorage>) -> u64 {
    let name = CString::new(name).unwrap();
    let platform = CString::new("windows").unwrap();
    // 0 would mean Bridgey's own port, 42458: take a free one.
    let free = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let config = BridgeyConfig {
        struct_size: std::mem::size_of::<BridgeyConfig>() as u32,
        port: free,
        listen: 1,
        discovery: 0,
        event_capacity: 0,
        device_name: name.as_ptr(),
        platform: platform.as_ptr(),
        data_dir: std::ptr::null(),
        receive_dir: std::ptr::null(),
        manual_connect: 0,
    };
    let mut handle = 0u64;
    let rc = unsafe { bridgey_client_new(&config, storage.map_or(std::ptr::null(), |s| s as *const _), &mut handle) };
    assert_eq!(rc, BRIDGEY_OK);
    handle
}

/// Pumps one client: confirms codes, returns every event seen until `until` matches one.
fn pump(handle: u64, until: impl Fn(&Owned) -> bool) -> Vec<Owned> {
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut seen = Vec::new();
    while Instant::now() < deadline {
        let mut event: *mut BridgeyEvent = std::ptr::null_mut();
        let rc = unsafe { bridgey_next_event(handle, 100, &mut event) };
        assert!(rc >= 0, "next_event {rc}");
        if rc == 0 {
            continue;
        }
        let e = unsafe { &*event };
        let owned = Owned { kind: e.kind, status: e.status, id: e.id, device_id: s(&e.device_id), text: s(&e.text) };
        unsafe { bridgey_event_free(event) };
        if owned.kind == BridgeyEventKind::PairingCode {
            assert_eq!(bridgey_pair_confirm(handle, owned.id, 1), BRIDGEY_OK);
        }
        let done = until(&owned);
        seen.push(owned);
        if done {
            return seen;
        }
    }
    panic!("timed out; saw {:?}", seen.iter().map(|e| e.kind).collect::<Vec<_>>());
}

fn port_of(handle: u64) -> u16 {
    let snap = bridgey_snapshot(handle);
    let v: serde_json::Value = serde_json::from_str(unsafe { CStr::from_ptr(snap) }.to_str().unwrap()).unwrap();
    unsafe { bridgey_string_free(snap) };
    v["port"].as_u64().unwrap() as u16
}

fn id_of(handle: u64) -> String {
    let p = bridgey_device_id(handle);
    let id = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { bridgey_string_free(p) };
    id
}

#[test]
fn pair_and_clipboard_through_the_c_abi() {
    assert_eq!(bridgey_abi_version(), BRIDGEY_ABI_VERSION);
    assert!(!unsafe { CStr::from_ptr(bridgey_version()) }.to_bytes().is_empty());
    let storage = BridgeyStorage { context: std::ptr::null_mut(), load: Some(load), store: Some(store), remove: Some(remove) };
    let a = start("PC", Some(&storage));
    let b = start("Laptop", None);
    let (a_id, b_id) = (id_of(a), id_of(b));
    assert!(STORE.lock().unwrap().as_ref().unwrap().contains_key("identity"), "the identity went through the host's storage");

    assert_eq!(bridgey_allow_pairing(b, u32::MAX), BRIDGEY_OK);
    let host = CString::new("127.0.0.1").unwrap();
    let mut pairing = 0u64;
    assert_eq!(unsafe { bridgey_pair(a, std::ptr::null(), host.as_ptr(), port_of(b), &mut pairing) }, BRIDGEY_OK);
    let b_thread = std::thread::spawn(move || pump(b, |e| e.kind == BridgeyEventKind::Features));
    let seen_a = pump(a, |e| e.kind == BridgeyEventKind::Features);
    let seen_b = b_thread.join().unwrap();
    let code_a = seen_a.iter().find(|e| e.kind == BridgeyEventKind::PairingCode).unwrap().text.clone();
    let code_b = seen_b.iter().find(|e| e.kind == BridgeyEventKind::PairingCode).unwrap().text.clone();
    assert_eq!(code_a, code_b);
    assert!(seen_a.iter().any(|e| e.kind == BridgeyEventKind::PairingFinished && e.id == pairing && e.status == 0));
    assert!(seen_a.iter().any(|e| e.kind == BridgeyEventKind::Connected && e.device_id.as_deref() == Some(b_id.as_str())));
    let trust = String::from_utf8(STORE.lock().unwrap().as_ref().unwrap()["trust"].clone()).unwrap();
    assert!(trust.contains(&b_id), "the trusted device went through the host's storage");

    // Text with a NUL inside travels with its exact length.
    let text = "one\0two ✓";
    let device = CString::new(b_id.clone()).unwrap();
    let mut request = 0u64;
    assert_eq!(unsafe { bridgey_send_clipboard(a, device.as_ptr(), text.as_ptr(), text.len(), &mut request) }, BRIDGEY_OK);
    let got = pump(b, |e| e.kind == BridgeyEventKind::Clipboard);
    assert_eq!(got.last().unwrap().text.as_deref(), Some(text));
    assert_eq!(got.last().unwrap().device_id.as_deref(), Some(a_id.as_str()));
    let sent = pump(a, |e| e.kind == BridgeyEventKind::ClipboardSent);
    assert_eq!((sent.last().unwrap().id, sent.last().unwrap().status), (request, BridgeySendStatus::Delivered as i32));

    // Wrong input is refused without touching the session.
    let bad = [0xffu8, 0xfe];
    assert_eq!(unsafe { bridgey_send_clipboard(a, device.as_ptr(), bad.as_ptr(), bad.len(), &mut request) }, BRIDGEY_ERR_INVALID_ARGUMENT);
    let nobody = CString::new("00000000-0000-4000-8000-000000000000").unwrap();
    assert_eq!(unsafe { bridgey_send_clipboard(a, nobody.as_ptr(), text.as_ptr(), text.len(), &mut request) }, BRIDGEY_ERR_NOT_CONNECTED);

    // Stop wakes the poll; a freed handle is refused, never dereferenced.
    assert_eq!(bridgey_client_stop(a), BRIDGEY_OK);
    let mut event: *mut BridgeyEvent = std::ptr::null_mut();
    loop {
        let rc = unsafe { bridgey_next_event(a, 1000, &mut event) };
        if rc == BRIDGEY_ERR_STOPPED {
            break;
        }
        unsafe { bridgey_event_free(event) };
    }
    bridgey_client_free(a);
    bridgey_client_free(b);
    assert_eq!(bridgey_allow_pairing(a, 10), BRIDGEY_ERR_STOPPED);
    assert!(bridgey_snapshot(b).is_null());
    unsafe { bridgey_event_free(std::ptr::null_mut()) };
    unsafe { bridgey_string_free(std::ptr::null_mut()) };
}

#[test]
fn bad_configuration_is_refused() {
    let mut out = 0u64;
    assert_eq!(unsafe { bridgey_client_new(std::ptr::null(), std::ptr::null(), &mut out) }, BRIDGEY_ERR_INVALID_ARGUMENT);
    let name = CString::new("x").unwrap();
    let config = BridgeyConfig {
        struct_size: 4,
        port: 0,
        listen: 0,
        discovery: 0,
        event_capacity: 0,
        device_name: name.as_ptr(),
        platform: name.as_ptr(),
        data_dir: std::ptr::null(),
        receive_dir: std::ptr::null(),
        manual_connect: 0,
    };
    assert_eq!(unsafe { bridgey_client_new(&config, std::ptr::null(), &mut out) }, BRIDGEY_ERR_INVALID_ARGUMENT, "struct_size too small");
    let half = BridgeyStorage { context: std::ptr::null_mut(), load: Some(load), store: None, remove: None };
    let config = BridgeyConfig { struct_size: std::mem::size_of::<BridgeyConfig>() as u32, ..config };
    assert_eq!(unsafe { bridgey_client_new(&config, &half, &mut out) }, BRIDGEY_ERR_INVALID_ARGUMENT, "all three callbacks");
}

/// A host built before receive_dir (the Windows app) passes the older, smaller struct; it still starts, and the
/// fields it does not have are never read.
#[test]
fn a_config_from_before_receive_dir_still_starts() {
    let name = CString::new("old host").unwrap();
    let platform = CString::new("windows").unwrap();
    let old_size = std::mem::offset_of!(BridgeyConfig, receive_dir) as u32;
    let config = BridgeyConfig {
        struct_size: old_size,
        port: std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port(),
        listen: 0,
        discovery: 0,
        event_capacity: 0,
        device_name: name.as_ptr(),
        platform: platform.as_ptr(),
        data_dir: std::ptr::null(),
        // Garbage the library must not read for a struct this size.
        receive_dir: std::ptr::dangling::<std::ffi::c_char>(),
        manual_connect: 7,
    };
    let mut handle = 0u64;
    assert_eq!(unsafe { bridgey_client_new(&config, std::ptr::null(), &mut handle) }, BRIDGEY_OK);
    bridgey_client_free(handle);
}
