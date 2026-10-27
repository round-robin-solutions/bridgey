//! The app interface: JSON commands in, JSON events out (docs/connect-anywhere.md, "Clients").
//!
//! Three calls on every platform: start, command, next event (a blocking poll with a timeout). The
//! Mac uses the C functions; Android the JNI functions below. Panics never cross the boundary.

use crate::node::{Node, PeerConfig, StartConfig};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::Duration;

struct Handle {
    node: Arc<Node>,
    events: Mutex<mpsc::Receiver<String>>,
}

fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("bridgey-connect").enable_all().build().expect("runtime"))
}

fn handles() -> &'static Mutex<HashMap<u64, Arc<Handle>>> {
    static HANDLES: OnceLock<Mutex<HashMap<u64, Arc<Handle>>>> = OnceLock::new();
    HANDLES.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT: AtomicU64 = AtomicU64::new(1);

fn error(message: impl std::fmt::Display) -> String {
    json!({"ok": false, "error": message.to_string()}).to_string()
}

fn guarded(f: impl FnOnce() -> String) -> String {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| error("internal error"))
}

/// Starts a node; the result is `{"ok":true,"handle":N,"udpPort":P}` or `{"ok":false,"error":...}`.
pub fn start(config: &str) -> String {
    guarded(|| {
        let cfg: StartConfig = match serde_json::from_str(config) {
            Ok(cfg) => cfg,
            Err(e) => return error(format!("config: {e}")),
        };
        let (tx, rx) = mpsc::channel::<String>();
        let tx = Mutex::new(tx);
        let sink = Arc::new(move |event: String| {
            let _ = tx.lock().unwrap().send(event);
        });
        match runtime().block_on(Node::start(cfg, sink)) {
            Ok(node) => {
                let id = NEXT.fetch_add(1, Ordering::Relaxed);
                let port = node.udp_port();
                handles().lock().unwrap().insert(id, Arc::new(Handle { node, events: Mutex::new(rx) }));
                json!({"ok": true, "handle": id, "udpPort": port}).to_string()
            }
            Err(e) => error(e),
        }
    })
}

fn handle(id: u64) -> Option<Arc<Handle>> {
    handles().lock().unwrap().get(&id).cloned()
}

pub fn command(id: u64, json_text: &str) -> String {
    guarded(|| {
        let Some(h) = handle(id) else { return error("no such node") };
        let Ok(cmd) = serde_json::from_str::<Value>(json_text) else { return error("not JSON") };
        let node = h.node.clone();
        let _guard = runtime().enter();
        match cmd.get("c").and_then(Value::as_str).unwrap_or_default() {
            "peers" => {
                let peers: Vec<PeerConfig> = match serde_json::from_value(cmd.get("peers").cloned().unwrap_or(Value::Null)) {
                    Ok(p) => p,
                    Err(e) => return error(format!("peers: {e}")),
                };
                match node.set_peers(peers) {
                    Ok(()) => json!({"ok": true}).to_string(),
                    Err(e) => error(e),
                }
            }
            "connect" => {
                node.connect(cmd.get("peer").and_then(Value::as_str).unwrap_or_default());
                json!({"ok": true}).to_string()
            }
            "network" => {
                node.network_changed(cmd.get("reason").and_then(Value::as_str).unwrap_or("network"));
                json!({"ok": true}).to_string()
            }
            "foreground" => {
                node.foreground();
                json!({"ok": true}).to_string()
            }
            "sign.result" => {
                let id = cmd.get("id").and_then(Value::as_u64).unwrap_or(0);
                let sig = cmd.get("sig").and_then(Value::as_str).and_then(bridgey_connect_proto::b64::std_decode);
                node.sign_result(id, sig);
                json!({"ok": true}).to_string()
            }
            "close" => {
                node.close_tunnel(cmd.get("tunnel").and_then(Value::as_str).unwrap_or_default());
                json!({"ok": true}).to_string()
            }
            "debug" => {
                if let Some(on) = cmd.get("relayOnly").and_then(Value::as_bool) {
                    node.set_relay_only(on);
                }
                json!({"ok": true}).to_string()
            }
            "status" => node.status().to_string(),
            "addresses" => node.addresses().to_string(),
            other => error(format!("unknown command {other}")),
        }
    })
}

/// The next event, or `None` after `timeout_ms` without one.
pub fn next_event(id: u64, timeout_ms: u32) -> Option<String> {
    let h = handle(id)?;
    let events = h.events.lock().ok()?;
    events.recv_timeout(Duration::from_millis(u64::from(timeout_ms))).ok()
}

pub fn stop(id: u64) {
    let handle = handles().lock().unwrap().remove(&id);
    if let Some(h) = handle {
        runtime().block_on(h.node.shutdown());
    }
}

mod c_abi {
    use std::ffi::{c_char, CStr, CString};

    fn take(ptr: *const c_char) -> String {
        if ptr.is_null() {
            return String::new();
        }
        // SAFETY: the caller passes a NUL-terminated UTF-8 string that outlives the call.
        unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
    }

    fn give(text: String) -> *mut c_char {
        CString::new(text).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub extern "C" fn bridgey_connect_start(config: *const c_char) -> *mut c_char {
        give(super::start(&take(config)))
    }

    #[no_mangle]
    pub extern "C" fn bridgey_connect_command(handle: u64, json: *const c_char) -> *mut c_char {
        give(super::command(handle, &take(json)))
    }

    #[no_mangle]
    pub extern "C" fn bridgey_connect_next_event(handle: u64, timeout_ms: u32) -> *mut c_char {
        super::next_event(handle, timeout_ms).map(give).unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub extern "C" fn bridgey_connect_stop(handle: u64) {
        let _ = std::panic::catch_unwind(|| super::stop(handle));
    }

    /// Frees a string returned by this library.
    #[no_mangle]
    pub extern "C" fn bridgey_connect_free(text: *mut c_char) {
        if !text.is_null() {
            // SAFETY: `text` came from CString::into_raw in this library and is freed once.
            drop(unsafe { CString::from_raw(text) });
        }
    }
}

#[cfg(target_os = "android")]
mod jni_abi {
    use jni::objects::{JClass, JString};
    use jni::sys::{jint, jlong, jstring};
    use jni::JNIEnv;

    fn read(env: &mut JNIEnv, text: &JString) -> String {
        env.get_string(text).map(|s| s.into()).unwrap_or_default()
    }

    fn give(env: &mut JNIEnv, text: String) -> jstring {
        env.new_string(text).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub extern "system" fn Java_dev_bridgey_android_connect_ConnectCore_nativeStart(mut env: JNIEnv, _: JClass, config: JString) -> jstring {
        let config = read(&mut env, &config);
        let result = super::start(&config);
        give(&mut env, result)
    }

    #[no_mangle]
    pub extern "system" fn Java_dev_bridgey_android_connect_ConnectCore_nativeCommand(mut env: JNIEnv, _: JClass, handle: jlong, json: JString) -> jstring {
        let json = read(&mut env, &json);
        let result = super::command(handle as u64, &json);
        give(&mut env, result)
    }

    #[no_mangle]
    pub extern "system" fn Java_dev_bridgey_android_connect_ConnectCore_nativeNextEvent(mut env: JNIEnv, _: JClass, handle: jlong, timeout_ms: jint) -> jstring {
        match std::panic::catch_unwind(|| super::next_event(handle as u64, timeout_ms.max(0) as u32)) {
            Ok(Some(event)) => give(&mut env, event),
            _ => std::ptr::null_mut(),
        }
    }

    #[no_mangle]
    pub extern "system" fn Java_dev_bridgey_android_connect_ConnectCore_nativeStop(_: JNIEnv, _: JClass, handle: jlong) {
        let _ = std::panic::catch_unwind(|| super::stop(handle as u64));
    }
}
